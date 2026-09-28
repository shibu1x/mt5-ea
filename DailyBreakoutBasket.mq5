//+------------------------------------------------------------------+
//|                                          DailyBreakoutBasket.mq5 |
//|              Daily Breakout Basket Expert Advisor                |
//+------------------------------------------------------------------+
#property copyright "Grid Trading EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

// Input Parameters
input group "=== Reference Price Entry ==="
input int      ReferenceHour = 1;                 // Reference Hour (server time, 0-23): the open of this hour's bar becomes the reference price
input int      ReferenceMaxDistancePips = 130;    // Max Distance from Reference Price to Allow Nanpin (pips, 0 = no limit)

input group "=== Basic Settings ==="
input double   LotSize = 0.01;              // Initial Lot Size
input double   LotMultiplier = 1.5;         // Lot Multiplier per Grid Level (1.0 = fixed lot)
input int      GridStepPips = 10;           // Grid Step (pips)
input double   GridStepMultiplier = 1.2;    // Grid Step Multiplier per Grid Level (1.0 = fixed step)
input int      BasketStopLossPips = 0;      // Basket Stop Loss (pips, volume-weighted avg, 0 = disabled)
input double   MaxSpreadPips = 1.0;         // Max Spread to Allow New Entries (pips, 0 = no limit)
input int      MagicNumber = 8080;          // Magic Number

input group "=== Trading Hours ==="
input int      TradingStartHour = 1;        // Trading Start Hour (server time, 0-23)
input int      TradingEndHour = 0;          // Trading End Hour (server time, 0-23; start == end means no restriction)

input group "=== Time-Window Profit Close ==="
input int      ProfitCloseStartHour = 21;    // Profit Close Window Start Hour (server time, 0-23; start == end disables this feature)
input int      ProfitCloseEndHour = 23;      // Profit Close Window End Hour (server time, 0-23)

input group "=== Buy Basket Settings ==="
input bool     BuyOpenNew = true;           // Open New Buy Baskets (false = close-only for an open basket)
input int      BuyMaxGridLevels = 16;       // Buy Max Grid Levels (0 = disabled)
input int      BuyBasketTakeProfitPips = 100; // Buy Basket Take Profit (pips, volume-weighted avg, 0 = disabled)
input int      BuyProfitCloseTargetPips = 10; // Buy Profit Close Target (pips, volume-weighted avg; negative = close even at a loss)
input double   BuyUpperLimitPrice = 0;      // Buy Upper Limit Price (0 = no limit)
input int      BuyEntryDistancePips = 0;    // Buy Level-0 Entry Distance Above Reference Price (pips, 0 = open at/above reference price; negative = allow entry below reference price)
input int      BuyEntryMaxDistancePips = 0; // Buy Level-0 Max Distance Beyond Entry Trigger Price to Allow Entry (pips, 0 = no limit)
input int      BuyPyramidMaxLevels = 0;     // Buy Pyramid Max Levels (0 = disabled)

input group "=== Sell Basket Settings ==="
input bool     SellOpenNew = true;          // Open New Sell Baskets (false = close-only for an open basket)
input int      SellMaxGridLevels = 16;      // Sell Max Grid Levels (0 = disabled)
input int      SellBasketTakeProfitPips = 100; // Sell Basket Take Profit (pips, volume-weighted avg, 0 = disabled)
input int      SellProfitCloseTargetPips = 10; // Sell Profit Close Target (pips, volume-weighted avg; negative = close even at a loss)
input double   SellLowerLimitPrice = 0;     // Sell Lower Limit Price (0 = no limit)
input int      SellEntryDistancePips = 0;   // Sell Level-0 Entry Distance Below Reference Price (pips, 0 = open at/below reference price; negative = allow entry above reference price)
input int      SellEntryMaxDistancePips = 0; // Sell Level-0 Max Distance Beyond Entry Trigger Price to Allow Entry (pips, 0 = no limit)
input int      SellPyramidMaxLevels = 0;    // Sell Pyramid Max Levels (0 = disabled)

input group "=== Pyramiding ==="
input int      PyramidStepPips = 10;            // Pyramid Step (pips): distance beyond the basket's best open price before adding a level
input double   PyramidStepMultiplier = 1.0;     // Pyramid Step Multiplier per Level (1.0 = fixed step)
input double   PyramidLotMultiplier = 1.0;      // Pyramid Lot Multiplier per Level (1.0 = fixed lot)

input group "=== Backtest Notification ==="
input bool     EnableBacktestCompleteNotification = false; // Send a push notification when a Strategy Tester run completes

// Global Variables
CTrade trade;
ulong  buyTickets[];
ulong  sellTickets[];
int gridStepPrice;
int pyramidStepPrice;
double pointValue;
double cachedLotSize;
int symbolDigits;
int buyUpperLimitInt;
int sellLowerLimitInt;
int maxSpreadPrice;
int referenceMaxDistancePrice;
int buyEntryDistancePrice;
int sellEntryDistancePrice;
int buyEntryMaxDistancePrice;
int sellEntryMaxDistancePrice;
int pipFactor;
bool tradingHoursRestricted;
int tradingStartMinutes;
int tradingEndMinutes;
bool profitCloseWindowEnabled;
int profitCloseStartMinutes;
int profitCloseEndMinutes;

// Reference price state: the open of the ReferenceHour bar. This EA is
// built to run on an H1 chart (enforced in OnInit), so one new PERIOD_CURRENT
// bar equals one new hour; re-checked on every new bar and refreshed
// whenever that bar's hour equals ReferenceHour, so it updates once per day
// without depending on the calendar date. referenceReady only ever goes
// false->true, on the very first successful capture, so referencePriceInt
// is never left empty for the EA's lifetime - a fresh start immediately
// catches up with the open of the most recent ReferenceHour bar (today's
// if already opened, otherwise yesterday's) instead of waiting for the next
// occurrence.
datetime lastBarTime = 0;
bool referenceReady = false;
int  referencePriceInt = 0;

//+------------------------------------------------------------------+
//| Convert pips to integer price units                              |
//+------------------------------------------------------------------+
int PipsToInt(double pips)
{
    return (int)MathRound(pips * pipFactor);
}

//+------------------------------------------------------------------+
//| Convert double price to integer price                            |
//+------------------------------------------------------------------+
int PriceToInt(double price)
{
    return (int)MathRound(price / pointValue);
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(10);
    trade.SetTypeFilling(ORDER_FILLING_FOK);

    pointValue    = _Point;
    symbolDigits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    pipFactor     = (symbolDigits == 3 || symbolDigits == 5) ? 10 : 100;
    cachedLotSize = MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
                    MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), LotSize));
    gridStepPrice = PipsToInt(GridStepPips);
    pyramidStepPrice = PipsToInt(PyramidStepPips);
    buyUpperLimitInt  = BuyUpperLimitPrice  > 0 ? PriceToInt(BuyUpperLimitPrice)  : 0;
    sellLowerLimitInt = SellLowerLimitPrice > 0 ? PriceToInt(SellLowerLimitPrice) : 0;
    maxSpreadPrice    = PipsToInt(MaxSpreadPips);
    referenceMaxDistancePrice = PipsToInt(ReferenceMaxDistancePips);
    buyEntryDistancePrice  = PipsToInt(BuyEntryDistancePips);
    sellEntryDistancePrice = PipsToInt(SellEntryDistancePips);
    buyEntryMaxDistancePrice  = PipsToInt(BuyEntryMaxDistancePips);
    sellEntryMaxDistancePrice = PipsToInt(SellEntryMaxDistancePips);

    tradingStartMinutes  = TradingStartHour * 60;
    tradingEndMinutes    = TradingEndHour * 60;
    tradingHoursRestricted = (tradingStartMinutes != tradingEndMinutes);

    profitCloseStartMinutes = ProfitCloseStartHour * 60;
    profitCloseEndMinutes   = ProfitCloseEndHour * 60;
    profitCloseWindowEnabled = (profitCloseStartMinutes != profitCloseEndMinutes);

    Print("=== DailyBreakoutBasket EA Initialization ===");
    Print("Entry Mode: Trend (fixed) - price up -> buy, price down -> sell");
    Print("Entry Trigger: capture the ", ReferenceHour, ":00 (server time) open as the daily reference price, ",
          "then open a buy basket once price has moved ", BuyEntryDistancePips,
          " pips above it and a sell basket once price has moved ", SellEntryDistancePips,
          " pips below it (negative = allow entry before price reaches the reference; each once per day per side), ",
          "skipping the entry entirely once price has already run more than ",
          "buy ", (BuyEntryMaxDistancePips > 0 ? IntegerToString(BuyEntryMaxDistancePips) + " pips" : "unlimited"),
          " / sell ", (SellEntryMaxDistancePips > 0 ? IntegerToString(SellEntryMaxDistancePips) + " pips" : "unlimited"),
          " beyond that trigger price");
    Print("Nanpin Stop Distance: ", (referenceMaxDistancePrice > 0 ?
          DoubleToString(ReferenceMaxDistancePips, 1) + " pips from the reference price" : "no limit"));
    Print("Grid Step: ", GridStepPips, " pips (", DoubleToString(gridStepPrice * pointValue, symbolDigits),
          ")  Step Multiplier: ", GridStepMultiplier);
    Print("Initial Lot: ", DoubleToString(cachedLotSize, 2),
          "  Multiplier: ", LotMultiplier,
          "  Max Levels: buy ", (GetMaxGridLevels(true)  == 0 ? "disabled" : IntegerToString(GetMaxGridLevels(true))),
          " / sell ", (GetMaxGridLevels(false) == 0 ? "disabled" : IntegerToString(GetMaxGridLevels(false))));
    Print("Max Spread: ", (maxSpreadPrice > 0 ? (DoubleToString(MaxSpreadPips, 1) + " pips") : "no limit"));
    Print("Trading Hours: ", (tradingHoursRestricted ?
          StringFormat("%02d:00-%02d:00 (server time)", TradingStartHour, TradingEndHour) :
          "no restriction"));
    Print("Profit Close Window: ", (profitCloseWindowEnabled ?
          StringFormat("%02d:00-%02d:00 (server time), closes a basket at buy %d+ pips / sell %d+ pips", ProfitCloseStartHour, ProfitCloseEndHour,
          BuyProfitCloseTargetPips, SellProfitCloseTargetPips) :
          "disabled"));
    Print("Basket TP: buy ", (BuyBasketTakeProfitPips  > 0 ? IntegerToString(BuyBasketTakeProfitPips)  + " pips" : "disabled"),
          " / sell ", (SellBasketTakeProfitPips > 0 ? IntegerToString(SellBasketTakeProfitPips) + " pips" : "disabled"),
          "  Basket SL: ", (BasketStopLossPips > 0 ? IntegerToString(BasketStopLossPips) + " pips" : "disabled"));
    Print("Pyramiding: step ", PyramidStepPips, " pips (x", DoubleToString(PyramidStepMultiplier, 2),
          "/level), lot x", DoubleToString(PyramidLotMultiplier, 2),
          "/level  Max Levels: buy ", (BuyPyramidMaxLevels  == 0 ? "disabled" : IntegerToString(BuyPyramidMaxLevels)),
          " / sell ", (SellPyramidMaxLevels == 0 ? "disabled" : IntegerToString(SellPyramidMaxLevels)));
    Print("Buy Basket: ", (BuyOpenNew ? "open new" : "close-only"),
          " Upper Limit: ", (buyUpperLimitInt > 0 ? DoubleToString(BuyUpperLimitPrice, symbolDigits) : "none"),
          " Entry Distance Above Reference: ", (buyEntryDistancePrice == 0 ? "at/above reference price" :
          (buyEntryDistancePrice > 0 ? IntegerToString(BuyEntryDistancePips) + " pips" : IntegerToString(-BuyEntryDistancePips) + " pips below reference price allowed")),
          " Max Distance Beyond Trigger: ", (buyEntryMaxDistancePrice > 0 ? IntegerToString(BuyEntryMaxDistancePips) + " pips" : "no limit"));
    Print("Sell Basket: ", (SellOpenNew ? "open new" : "close-only"),
          " Lower Limit: ", (sellLowerLimitInt > 0 ? DoubleToString(SellLowerLimitPrice, symbolDigits) : "none"),
          " Entry Distance Below Reference: ", (sellEntryDistancePrice == 0 ? "at/below reference price" :
          (sellEntryDistancePrice > 0 ? IntegerToString(SellEntryDistancePips) + " pips" : IntegerToString(-SellEntryDistancePips) + " pips above reference price allowed")),
          " Max Distance Beyond Trigger: ", (sellEntryMaxDistancePrice > 0 ? IntegerToString(SellEntryMaxDistancePips) + " pips" : "no limit"));

    // Both sides may be close-only at once: a pure wind-down of open baskets
    // with no new entries is a valid configuration, so it is not rejected here.

    if(_Period != PERIOD_H1)
    {
        Print("Error: This EA must run on an H1 chart");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(ReferenceHour < 0 || ReferenceHour > 23)
    {
        Print("Error: Reference hour must be within 0-23");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(ReferenceMaxDistancePips < 0)
    {
        Print("Error: Reference max distance must be non-negative");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(BuyEntryMaxDistancePips < 0 || SellEntryMaxDistancePips < 0)
    {
        Print("Error: Entry max distance values must be non-negative");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(LotMultiplier <= 0)
    {
        Print("Error: Lot multiplier must be positive");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(GridStepMultiplier <= 0)
    {
        Print("Error: Grid step multiplier must be positive");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(BuyMaxGridLevels < 0 || SellMaxGridLevels < 0)
    {
        Print("Error: Max grid levels values must be non-negative");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(BuyBasketTakeProfitPips < 0 || SellBasketTakeProfitPips < 0)
    {
        Print("Error: Basket take profit values must be non-negative");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(TradingStartHour < 0 || TradingStartHour > 23 || TradingEndHour < 0 || TradingEndHour > 23)
    {
        Print("Error: Trading hour values must be within 0-23");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(ProfitCloseStartHour < 0 || ProfitCloseStartHour > 23 || ProfitCloseEndHour < 0 || ProfitCloseEndHour > 23)
    {
        Print("Error: Profit close window hour values must be within 0-23");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(PyramidStepPips < 0)
    {
        Print("Error: Pyramid step must be non-negative");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(PyramidStepMultiplier <= 0)
    {
        Print("Error: Pyramid step multiplier must be positive");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(PyramidLotMultiplier <= 0)
    {
        Print("Error: Pyramid lot multiplier must be positive");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(BuyPyramidMaxLevels < 0 || SellPyramidMaxLevels < 0)
    {
        Print("Error: Pyramid max levels values must be non-negative");
        return INIT_PARAMETERS_INCORRECT;
    }

    Print("Initialization Complete");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("DailyBreakoutBasket EA Terminated");
}

//+------------------------------------------------------------------+
//| Called once after an entire optimization run finishes (all       |
//| passes done), in the managing terminal instance. Guarded by       |
//| MQL_OPTIMIZATION so a plain (non-optimization) backtest never     |
//| sends a notification - only a completed optimization does.       |
//+------------------------------------------------------------------+
void OnTesterDeinit()
{
    if(EnableBacktestCompleteNotification && MQLInfoInteger(MQL_OPTIMIZATION))
        SendNotification("DailyBreakoutBasket: optimization complete");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    UpdateReference();

    int    buyCount = 0, sellCount = 0;
    double buyProfit = 0, sellProfit = 0;
    int    buyExtremePriceInt = 999999999, sellExtremePriceInt = 0;
    int    buyFavorableExtremePriceInt = 0, sellFavorableExtremePriceInt = 999999999;
    int    buyPyramidCount = 0, sellPyramidCount = 0;
    double buyPipsProfit = 0, sellPipsProfit = 0;

    CollectBasketData(buyCount, buyProfit, buyExtremePriceInt, buyFavorableExtremePriceInt, buyPyramidCount, buyPipsProfit,
                       sellCount, sellProfit, sellExtremePriceInt, sellFavorableExtremePriceInt, sellPyramidCount, sellPipsProfit);

    ManageBasket(true,  buyCount,  buyProfit,  buyExtremePriceInt,  buyFavorableExtremePriceInt,  buyPyramidCount,  buyPipsProfit);
    ManageBasket(false, sellCount, sellProfit, sellExtremePriceInt, sellFavorableExtremePriceInt, sellPyramidCount, sellPipsProfit);
}

//+------------------------------------------------------------------+
//| Hour component (server time, 0-23) of the given datetime          |
//+------------------------------------------------------------------+
int GetHour(datetime t)
{
    MqlDateTime dt;
    TimeToStruct(t, dt);
    return dt.hour;
}

//+------------------------------------------------------------------+
//| Shift (bars back from the still-forming bar 0) of the most recent |
//| bar whose open lines up with ReferenceHour:00: today's if that    |
//| hour has already opened (including the still-forming bar 0),      |
//| otherwise yesterday's. Assumes one PERIOD_CURRENT bar == one hour |
//| (H1 chart, enforced in OnInit).                                   |
//+------------------------------------------------------------------+
int GetLastReferenceShift()
{
    int shift = GetHour(iTime(_Symbol, PERIOD_CURRENT, 0)) - ReferenceHour;
    if(shift < 0) shift += 24;
    return shift;
}

//+------------------------------------------------------------------+
//| Capture the open of the bar at the given shift into                |
//| referencePriceInt. Leaves the previous value untouched if that    |
//| bar's history isn't available yet (referenceReady stays false     |
//| until the first successful capture, so callers keep retrying).    |
//+------------------------------------------------------------------+
void CaptureReferencePrice(int shift)
{
    double open = iOpen(_Symbol, PERIOD_CURRENT, shift);
    if(open <= 0) return;

    referencePriceInt = PriceToInt(open);
    referenceReady = true;

    Print("Reference price captured for ", TimeToString(iTime(_Symbol, PERIOD_CURRENT, shift), TIME_DATE | TIME_MINUTES));
    Print("Reference price: ", DoubleToString(referencePriceInt * pointValue, symbolDigits));
}

//+------------------------------------------------------------------+
//| Keep referencePriceInt up to date. The reference price itself     |
//| never resets to an empty state: on first run it immediately       |
//| catches up with the most recent ReferenceHour bar's open, and     |
//| afterwards is only re-checked on each new bar, refreshing it as    |
//| soon as a new bar's hour equals ReferenceHour (its open is known   |
//| the instant the bar starts forming, no need to wait for its close).|
//+------------------------------------------------------------------+
void UpdateReference()
{
    if(!referenceReady)
    {
        lastBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
        CaptureReferencePrice(GetLastReferenceShift());
        return;
    }

    datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(barTime == lastBarTime) return;
    lastBarTime = barTime;

    if(GetHour(barTime) != ReferenceHour) return;

    CaptureReferencePrice(0);
}

//+------------------------------------------------------------------+
//| Single PositionsTotal() pass that fills in both baskets' status  |
//| (count, floating profit, volume-weighted average pips profit,    |
//| adverse extreme open price, favorable extreme open price,        |
//| pyramid level count) in one scan instead of one scan per          |
//| direction, and caches each basket's tickets in buyTickets[] /     |
//| sellTickets[] so CloseBasket() can close by ticket instead of     |
//| re-scanning all positions. Each side's mark price is the price a |
//| position of that direction would actually close at (Bid for buy, |
//| Ask for sell), matching what CloseBasket() will actually realize.|
//| buyExtremePriceInt/sellExtremePriceInt is the worst (most         |
//| adverse) open price on that side, used by the nanpin grid; the    |
//| favorable variant is the best open price, used by the pyramid     |
//| add. A position's comment starting with "Basket P" (set by        |
//| OpenGridOrder(..., true)) is a pyramid add and is counted in       |
//| buyPyramidCount/sellPyramidCount, which ManageBasket() subtracts   |
//| from count to get the nanpin-only level count.                    |
//+------------------------------------------------------------------+
void CollectBasketData(int &buyCount, double &buyProfit, int &buyExtremePriceInt, int &buyFavorableExtremePriceInt, int &buyPyramidCount, double &buyPipsProfit,
                        int &sellCount, double &sellProfit, int &sellExtremePriceInt, int &sellFavorableExtremePriceInt, int &sellPyramidCount, double &sellPipsProfit)
{
    ArrayResize(buyTickets, 0);
    ArrayResize(sellTickets, 0);

    double buyWeightedSum = 0, buyVolume = 0;
    double sellWeightedSum = 0, sellVolume = 0;

    int buyMarkPriceInt  = PriceToInt(SymbolInfoDouble(_Symbol, SYMBOL_BID));
    int sellMarkPriceInt = PriceToInt(SymbolInfoDouble(_Symbol, SYMBOL_ASK));

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket <= 0) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

        ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        bool isBuy = (type == POSITION_TYPE_BUY);
        double volume = PositionGetDouble(POSITION_VOLUME);
        int openPrice = PriceToInt(PositionGetDouble(POSITION_PRICE_OPEN));
        double posProfit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
        bool isPyramid = (StringFind(PositionGetString(POSITION_COMMENT), "Basket P") == 0);

        if(isBuy)
        {
            buyCount++;
            buyProfit += posProfit;
            buyWeightedSum += (buyMarkPriceInt - openPrice) * volume;
            buyVolume += volume;
            if(openPrice < buyExtremePriceInt) buyExtremePriceInt = openPrice;
            if(openPrice > buyFavorableExtremePriceInt) buyFavorableExtremePriceInt = openPrice;
            if(isPyramid) buyPyramidCount++;

            int n = ArraySize(buyTickets);
            ArrayResize(buyTickets, n + 1);
            buyTickets[n] = ticket;
        }
        else
        {
            sellCount++;
            sellProfit += posProfit;
            sellWeightedSum += (openPrice - sellMarkPriceInt) * volume;
            sellVolume += volume;
            if(openPrice > sellExtremePriceInt) sellExtremePriceInt = openPrice;
            if(openPrice < sellFavorableExtremePriceInt) sellFavorableExtremePriceInt = openPrice;
            if(isPyramid) sellPyramidCount++;

            int n = ArraySize(sellTickets);
            ArrayResize(sellTickets, n + 1);
            sellTickets[n] = ticket;
        }
    }

    buyPipsProfit  = buyVolume  > 0 ? (buyWeightedSum  / buyVolume)  / pipFactor : 0;
    sellPipsProfit = sellVolume > 0 ? (sellWeightedSum / sellVolume) / pipFactor : 0;
}

//+------------------------------------------------------------------+
//| Manage a basket: open the initial position, add grid levels as   |
//| price moves further against the basket (nanpin) or in its favor  |
//| (pyramid), and close the whole basket once the take profit /      |
//| stop loss target is reached                                       |
//+------------------------------------------------------------------+
void ManageBasket(bool isBuy, int count, double profit, int extremePriceInt, int favorableExtremePriceInt, int pyramidCount, double pipsProfit)
{
    int currentPrice = isBuy ? PriceToInt(SymbolInfoDouble(_Symbol, SYMBOL_ASK))
                              : PriceToInt(SymbolInfoDouble(_Symbol, SYMBOL_BID));

    // A close-only side never starts a new basket; an already-open one is still
    // managed (grid adds + TP/SL) so it can wind down.
    bool openNew = isBuy ? BuyOpenNew : SellOpenNew;

    if(count == 0)
    {
        if(openNew && IsWithinTradingHours() && IsWithinLimit(isBuy, currentPrice) && IsSpreadAllowed() && referenceReady && HasReachedEntryDistance(isBuy, currentPrice))
        {
            OpenGridOrder(isBuy, 0);
        }
        return;
    }

    int basketTakeProfitPips = GetBasketTakeProfitPips(isBuy);
    if(IsWithinTradingHours() &&
       ((basketTakeProfitPips > 0 && pipsProfit >= basketTakeProfitPips) ||
        (BasketStopLossPips   > 0 && pipsProfit <= -BasketStopLossPips)))
    {
        CloseBasket(isBuy, profit, pipsProfit);
        return;
    }

    int profitCloseTargetPips = GetProfitCloseTargetPips(isBuy);
    if(IsWithinProfitCloseWindow() && pipsProfit >= profitCloseTargetPips)
    {
        CloseBasket(isBuy, profit, pipsProfit);
        return;
    }

    // Nanpin (adverse-move) grid add: counted separately from pyramid adds
    // (nanpinCount = count - pyramidCount) so pyramid levels don't inflate the
    // nanpin step/lot progression (CalculateGridStepPrice/CalculateLotSize) or
    // its own level cap.
    int nanpinCount = count - pyramidCount;
    int maxLevels = GetMaxGridLevels(isBuy);
    if(maxLevels > 0 && nanpinCount < maxLevels)
    {
        int stepPrice = CalculateGridStepPrice(nanpinCount);
        bool triggered = isBuy ? (currentPrice <= extremePriceInt - stepPrice)
                                : (currentPrice >= extremePriceInt + stepPrice);

        if(triggered && IsWithinTradingHours() && IsSpreadAllowed() && IsWithinReferenceDistance(isBuy, currentPrice))
        {
            OpenGridOrder(isBuy, nanpinCount);
            return;
        }
    }

    // Pyramid (favorable-move) add: adds further in the basket's profit
    // direction once price clears favorableExtremePriceInt (the best open
    // price already in the basket) by a pyramid step - its own step/lot
    // multipliers and level cap, independent of the nanpin progression above.
    // Not gated by IsWithinReferenceDistance(), which is a nanpin-only
    // stop-distance filter. A max level of 0 disables pyramiding for that
    // side entirely, same convention as MaxGridLevels for the nanpin grid.
    int pyramidMaxLevels = GetPyramidMaxLevels(isBuy);
    if(pyramidMaxLevels > 0 && pyramidCount < pyramidMaxLevels)
    {
        int pyramidStep = CalculatePyramidStepPrice(pyramidCount);
        bool pyramidTriggered = isBuy ? (currentPrice >= favorableExtremePriceInt + pyramidStep)
                                       : (currentPrice <= favorableExtremePriceInt - pyramidStep);

        if(pyramidTriggered && IsWithinTradingHours() && IsSpreadAllowed())
        {
            OpenGridOrder(isBuy, pyramidCount, true);
        }
    }
}

//+------------------------------------------------------------------+
//| Nanpin stop-distance filter: once price has moved more than      |
//| ReferenceMaxDistancePips away from this side's entry basis       |
//| (either direction), grid-level additions are suspended - the     |
//| basket is still monitored for TP/SL and the level-0 entry is     |
//| unaffected. The entry basis is the reference price adjusted by   |
//| this side's entry distance - referencePriceInt + buyEntryDistancePrice |
//| for buy, referencePriceInt - sellEntryDistancePrice for sell -   |
//| i.e. the same price level HasReachedEntryDistance() requires     |
//| price to have reached before level 0 may open. 0 = no limit.     |
//+------------------------------------------------------------------+
bool IsWithinReferenceDistance(bool isBuy, int currentPriceInt)
{
    if(referenceMaxDistancePrice <= 0) return true;
    if(!referenceReady) return true;

    int distancePrice = isBuy ? buyEntryDistancePrice : sellEntryDistancePrice;
    int basePriceInt = isBuy ? (referencePriceInt + distancePrice) : (referencePriceInt - distancePrice);
    return MathAbs(currentPriceInt - basePriceInt) <= referenceMaxDistancePrice;
}

//+------------------------------------------------------------------+
//| Trend entry-distance gate for a new basket's level-0 position:   |
//| requires price to have already moved BuyEntryDistancePips above  |
//| (buy) / SellEntryDistancePips below (sell) today's reference      |
//| price before that side may open - a distance of 0 requires price |
//| to be at or beyond the reference price itself (buy: at/above it, |
//| sell: at/below it). A negative distance relaxes the gate so that |
//| side may open before price reaches the reference (buy: still up  |
//| to |distance| pips below it; sell: still up to |distance| pips   |
//| above it). BuyEntryMaxDistancePips/SellEntryMaxDistancePips (0 =  |
//| no limit) then caps how far beyond that trigger price is still   |
//| allowed to open a fresh basket - once price has already run      |
//| further than the trigger price + that many pips, the breakout is |
//| considered missed and level 0 is skipped for the rest of today's  |
//| qualifying move (grid adds to an already-open basket are          |
//| unaffected). Only applies to the position that starts a new       |
//| basket, not grid-level additions.                                 |
//+------------------------------------------------------------------+
bool HasReachedEntryDistance(bool isBuy, int currentPriceInt)
{
    if(!referenceReady) return false;

    int distancePrice = isBuy ? buyEntryDistancePrice : sellEntryDistancePrice;
    int triggerPriceInt = isBuy ? (referencePriceInt + distancePrice) : (referencePriceInt - distancePrice);
    bool reached = isBuy ? (currentPriceInt >= triggerPriceInt) : (currentPriceInt <= triggerPriceInt);
    if(!reached) return false;

    int maxDistancePrice = isBuy ? buyEntryMaxDistancePrice : sellEntryMaxDistancePrice;
    if(maxDistancePrice <= 0) return true;

    return isBuy ? (currentPriceInt <= triggerPriceInt + maxDistancePrice)
                 : (currentPriceInt >= triggerPriceInt - maxDistancePrice);
}

//+------------------------------------------------------------------+
//| Resolve the effective max grid levels for a basket: the          |
//| per-direction BuyMaxGridLevels / SellMaxGridLevels (0 =          |
//| disabled - the nanpin grid has no unlimited mode).               |
//+------------------------------------------------------------------+
int GetMaxGridLevels(bool isBuy)
{
    return isBuy ? BuyMaxGridLevels : SellMaxGridLevels;
}

//+------------------------------------------------------------------+
//| Resolve the effective pyramid max levels for a basket: the        |
//| per-direction BuyPyramidMaxLevels / SellPyramidMaxLevels (0 =     |
//| disabled, same convention as MaxGridLevels for the nanpin grid).  |
//+------------------------------------------------------------------+
int GetPyramidMaxLevels(bool isBuy)
{
    return isBuy ? BuyPyramidMaxLevels : SellPyramidMaxLevels;
}

//+------------------------------------------------------------------+
//| Resolve the effective basket take profit for a basket: the       |
//| per-direction BuyBasketTakeProfitPips / SellBasketTakeProfitPips |
//| (0 = disabled).                                                  |
//+------------------------------------------------------------------+
int GetBasketTakeProfitPips(bool isBuy)
{
    return isBuy ? BuyBasketTakeProfitPips : SellBasketTakeProfitPips;
}

//+------------------------------------------------------------------+
//| Resolve the effective time-window profit close target for a      |
//| basket: the per-direction BuyProfitCloseTargetPips /              |
//| SellProfitCloseTargetPips (always active while the profit close  |
//| window is enabled; negative closes even at a loss).              |
//+------------------------------------------------------------------+
int GetProfitCloseTargetPips(bool isBuy)
{
    return isBuy ? BuyProfitCloseTargetPips : SellProfitCloseTargetPips;
}

//+------------------------------------------------------------------+
//| Calculate the grid step distance required to open the given       |
//| grid level, scaling by GridStepMultiplier per level               |
//+------------------------------------------------------------------+
int CalculateGridStepPrice(int level)
{
    return (int)MathRound(gridStepPrice * MathPow(GridStepMultiplier, MathMax(level - 1, 0)));
}

//+------------------------------------------------------------------+
//| Calculate the pyramid step distance required to open the given    |
//| pyramid level, scaling by PyramidStepMultiplier per level          |
//+------------------------------------------------------------------+
int CalculatePyramidStepPrice(int level)
{
    return (int)MathRound(pyramidStepPrice * MathPow(PyramidStepMultiplier, MathMax(level - 1, 0)));
}

//+------------------------------------------------------------------+
//| Check whether a price is within the basket's initial-entry limit |
//| (buy: at or below BuyUpperLimitPrice; sell: at or above           |
//| SellLowerLimitPrice); a limit of 0 means no restriction. Only    |
//| applies to the position that starts a new basket, not grid-level |
//| additions.                                                        |
//+------------------------------------------------------------------+
bool IsWithinLimit(bool isBuy, int priceInt)
{
    if(isBuy) return buyUpperLimitInt == 0 || priceInt <= buyUpperLimitInt;
    return sellLowerLimitInt == 0 || priceInt >= sellLowerLimitInt;
}

//+------------------------------------------------------------------+
//| Check whether the current spread allows new entries               |
//+------------------------------------------------------------------+
bool IsSpreadAllowed()
{
    if(maxSpreadPrice == 0) return true;
    int spreadPrice = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    return spreadPrice <= maxSpreadPrice;
}

//+------------------------------------------------------------------+
//| Check whether the current server time falls within the allowed   |
//| trading hours window (wraps past midnight if start > end); gates |
//| both new entries and basket TP/SL closing                        |
//+------------------------------------------------------------------+
bool IsWithinTradingHours()
{
    if(!tradingHoursRestricted) return true;

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int nowMinutes = dt.hour * 60 + dt.min;

    if(tradingStartMinutes < tradingEndMinutes)
        return nowMinutes >= tradingStartMinutes && nowMinutes < tradingEndMinutes;

    return nowMinutes >= tradingStartMinutes || nowMinutes < tradingEndMinutes;
}

//+------------------------------------------------------------------+
//| Check whether the current server time falls within the profit    |
//| close window (wraps past midnight if start > end, same           |
//| convention as IsWithinTradingHours()); disabled when              |
//| ProfitCloseStartHour == ProfitCloseEndHour. Gates the extra exit  |
//| that closes a basket once it reaches its side's                  |
//| BuyProfitCloseTargetPips/SellProfitCloseTargetPips, independent   |
//| of BuyBasketTakeProfitPips/SellBasketTakeProfitPips and           |
//| TradingStartHour/TradingEndHour.                                   |
//+------------------------------------------------------------------+
bool IsWithinProfitCloseWindow()
{
    if(!profitCloseWindowEnabled) return false;

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int nowMinutes = dt.hour * 60 + dt.min;

    if(profitCloseStartMinutes < profitCloseEndMinutes)
        return nowMinutes >= profitCloseStartMinutes && nowMinutes < profitCloseEndMinutes;

    return nowMinutes >= profitCloseStartMinutes || nowMinutes < profitCloseEndMinutes;
}

//+------------------------------------------------------------------+
//| Calculate lot size for a grid level, scaling by LotMultiplier    |
//| from the fixed base cachedLotSize (LotSize clamped at OnInit)    |
//+------------------------------------------------------------------+
double CalculateLotSize(int level)
{
    double lot = cachedLotSize * MathPow(LotMultiplier, level);

    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double lotMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double lotMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

    lot = MathRound(lot / lotStep) * lotStep;
    return MathMax(lotMin, MathMin(lotMax, lot));
}

//+------------------------------------------------------------------+
//| Calculate lot size for a pyramid level, scaling by                |
//| PyramidLotMultiplier from the fixed base cachedLotSize            |
//+------------------------------------------------------------------+
double CalculatePyramidLotSize(int level)
{
    double lot = cachedLotSize * MathPow(PyramidLotMultiplier, level);

    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double lotMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double lotMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

    lot = MathRound(lot / lotStep) * lotStep;
    return MathMax(lotMin, MathMin(lotMax, lot));
}

//+------------------------------------------------------------------+
//| Open a market order for the next level of a basket - a nanpin    |
//| (adverse-move) grid add by default, or a pyramid (favorable-move) |
//| add when isPyramid is true, which uses PyramidLotMultiplier for   |
//| lot sizing and a distinct "Basket P%d" comment so                 |
//| CollectBasketData() can count pyramid levels separately from      |
//| nanpin levels.                                                    |
//+------------------------------------------------------------------+
bool OpenGridOrder(bool isBuy, int level, bool isPyramid = false)
{
    double lot = isPyramid ? CalculatePyramidLotSize(level) : CalculateLotSize(level);
    string comment = StringFormat(isPyramid ? "Basket P%d" : "Basket L%d", level);

    bool result = isBuy ? trade.Buy(lot, _Symbol, 0, 0, 0, comment)
                         : trade.Sell(lot, _Symbol, 0, 0, 0, comment);

    if(result)
        Print((isBuy ? "Buy" : "Sell"), " ", (isPyramid ? "pyramid" : "grid"), " order opened: Level ", level, " Lot ", DoubleToString(lot, 2));
    else
        Print((isBuy ? "Buy" : "Sell"), " ", (isPyramid ? "pyramid" : "grid"), " order failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());

    return result;
}

//+------------------------------------------------------------------+
//| Close every position belonging to a basket, by the tickets       |
//| CollectBasketData() already cached this tick - avoids a second   |
//| full PositionsTotal() scan on top of the one CollectBasketData() |
//| just did.                                                         |
//+------------------------------------------------------------------+
void CloseBasket(bool isBuy, double profit, double pipsProfit)
{
    double totalLots = 0;
    int    closedCount = 0;
    int    n = isBuy ? ArraySize(buyTickets) : ArraySize(sellTickets);

    for(int i = 0; i < n; i++)
    {
        ulong ticket = isBuy ? buyTickets[i] : sellTickets[i];
        if(!PositionSelectByTicket(ticket)) continue;

        totalLots += PositionGetDouble(POSITION_VOLUME);
        if(trade.PositionClose(ticket)) closedCount++;
    }

    Print((isBuy ? "Buy" : "Sell"), " basket closed: ", closedCount, " position(s), ",
          DoubleToString(totalLots, 2), " lots, Profit ", DoubleToString(profit, 2),
          " (", DoubleToString(pipsProfit, 1), " pips)");
}
