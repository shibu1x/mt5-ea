//+------------------------------------------------------------------+
//|                                          DailyStraddleBasket.mq5 |
//|              Daily Straddle Basket Expert Advisor                |
//+------------------------------------------------------------------+
#property copyright "Grid Trading EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

// Input Parameters
input group "=== Reference Price Entry ==="
input int      ReferenceHour = 1;                 // Reference Hour (server time, 0-23): the close of this hour's bar becomes the reference price
input int      ReferenceMaxDistancePips = 130;    // Max Distance from Reference Price to Allow Nanpin (pips, 0 = no limit)

input group "=== Basic Settings ==="
input double   LotSize = 0.01;              // Initial Lot Size
input double   LotMultiplier = 1.5;         // Lot Multiplier per Grid Level (1.0 = fixed lot)
input int      GridStepPips = 10;           // Grid Step (pips)
input double   GridStepMultiplier = 1.2;    // Grid Step Multiplier per Grid Level (1.0 = fixed step)
input int      MaxGridLevels = 16;          // Max Grid Levels (common, 0 = unlimited; used unless a per-direction value is set)
input int      BasketTakeProfitPips = 100;  // Basket Take Profit (pips, volume-weighted avg, 0 = disabled)
input int      BasketStopLossPips = 0;      // Basket Stop Loss (pips, volume-weighted avg, 0 = disabled)
input double   MaxSpreadPips = 1.0;         // Max Spread to Allow New Entries (pips, 0 = no limit)
input int      MagicNumber = 8007;          // Magic Number

input group "=== Trading Hours ==="
input int      TradingStartHour = 1;        // Trading Start Hour (server time, 0-23)
input int      TradingEndHour = 0;          // Trading End Hour (server time, 0-23; start == end means no restriction)

input group "=== Time-Window Profit Close ==="
input int      ProfitCloseStartHour = 21;    // Profit Close Window Start Hour (server time, 0-23; start == end disables this feature)
input int      ProfitCloseEndHour = 23;      // Profit Close Window End Hour (server time, 0-23)
input int      ProfitCloseTargetPips = 10;   // Profit Close Target (pips, volume-weighted avg, 0 = disabled)

input group "=== Buy Basket Settings ==="
input bool     BuyOpenNew = true;           // Open New Buy Baskets (false = close-only for an open basket)
input int      BuyMaxGridLevels = 0;        // Buy Max Grid Levels (0 = use common MaxGridLevels; >=1 overrides it)
input double   BuyUpperLimitPrice = 0;      // Buy Upper Limit Price (0 = no limit)
input int      BuyEntryDistancePips = 0;    // Buy Level-0 Entry Distance Below Reference Price (pips, 0 = open at/below reference price; negative = allow entry above reference price)

input group "=== Sell Basket Settings ==="
input bool     SellOpenNew = true;          // Open New Sell Baskets (false = close-only for an open basket)
input int      SellMaxGridLevels = 0;       // Sell Max Grid Levels (0 = use common MaxGridLevels; >=1 overrides it)
input double   SellLowerLimitPrice = 0;     // Sell Lower Limit Price (0 = no limit)
input int      SellEntryDistancePips = 0;   // Sell Level-0 Entry Distance Above Reference Price (pips, 0 = open at/above reference price; negative = allow entry below reference price)

// Global Variables
CTrade trade;
int gridStepPrice;
double pointValue;
double cachedLotSize;
int symbolDigits;
int buyUpperLimitInt;
int sellLowerLimitInt;
int maxSpreadPrice;
int referenceMaxDistancePrice;
int buyEntryDistancePrice;
int sellEntryDistancePrice;
int pipFactor;
bool tradingHoursRestricted;
int tradingStartMinutes;
int tradingEndMinutes;
bool profitCloseWindowEnabled;
int profitCloseStartMinutes;
int profitCloseEndMinutes;

// Reference price state: the close of the ReferenceHour bar. This EA is
// built to run on an H1 chart (enforced in OnInit), so one new PERIOD_CURRENT
// bar equals one new hour; re-checked on every new bar and refreshed
// whenever that bar's hour equals ReferenceHour, so it updates once per day
// without depending on the calendar date. referenceReady only ever goes
// false->true, on the very first successful capture, so referencePriceInt
// is never left empty for the EA's lifetime - a fresh start immediately
// catches up with the close of the most recent ReferenceHour bar (today's
// if already passed, otherwise yesterday's) instead of waiting for the next
// occurrence.
// buyEnteredToday / sellEnteredToday gate each side's level-0 basket to at
// most one open per day off that reference, even if the basket closes
// (TP/SL) and goes flat again before the day rolls over; they still reset
// on calendar date change since that gate is independent of the hour-based
// reference price update above.
int  referenceDay   = 0;
int  referenceMonth = 0;
int  referenceYear  = 0;
datetime lastBarTime = 0;
bool referenceReady = false;
int  referencePriceInt = 0;
bool buyEnteredToday  = false;
bool sellEnteredToday = false;

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
    buyUpperLimitInt  = BuyUpperLimitPrice  > 0 ? PriceToInt(BuyUpperLimitPrice)  : 0;
    sellLowerLimitInt = SellLowerLimitPrice > 0 ? PriceToInt(SellLowerLimitPrice) : 0;
    maxSpreadPrice    = PipsToInt(MaxSpreadPips);
    referenceMaxDistancePrice = PipsToInt(ReferenceMaxDistancePips);
    buyEntryDistancePrice  = PipsToInt(BuyEntryDistancePips);
    sellEntryDistancePrice = PipsToInt(SellEntryDistancePips);

    tradingStartMinutes  = TradingStartHour * 60;
    tradingEndMinutes    = TradingEndHour * 60;
    tradingHoursRestricted = (tradingStartMinutes != tradingEndMinutes);

    profitCloseStartMinutes = ProfitCloseStartHour * 60;
    profitCloseEndMinutes   = ProfitCloseEndHour * 60;
    profitCloseWindowEnabled = (profitCloseStartMinutes != profitCloseEndMinutes);

    Print("=== DailyStraddleBasket EA Initialization ===");
    Print("Entry Trigger: capture the ", ReferenceHour, ":00 (server time) close as the daily reference price, ",
          "then open a buy basket once price has moved ", BuyEntryDistancePips,
          " pips below it and a sell basket once price has moved ", SellEntryDistancePips,
          " pips above it (negative = allow entry before price reaches the reference; each once per day per side)");
    Print("Nanpin Stop Distance: ", (referenceMaxDistancePrice > 0 ?
          DoubleToString(ReferenceMaxDistancePips, 1) + " pips from the reference price" : "no limit"));
    Print("Grid Step: ", GridStepPips, " pips (", DoubleToString(gridStepPrice * pointValue, symbolDigits),
          ")  Step Multiplier: ", GridStepMultiplier);
    Print("Initial Lot: ", DoubleToString(cachedLotSize, 2),
          "  Multiplier: ", LotMultiplier,
          "  Max Levels (common): ", (MaxGridLevels == 0 ? "unlimited" : IntegerToString(MaxGridLevels)),
          "  buy ", (GetMaxGridLevels(true)  == 0 ? "unlimited" : IntegerToString(GetMaxGridLevels(true))),
          " / sell ", (GetMaxGridLevels(false) == 0 ? "unlimited" : IntegerToString(GetMaxGridLevels(false))));
    Print("Max Spread: ", (maxSpreadPrice > 0 ? (DoubleToString(MaxSpreadPips, 1) + " pips") : "no limit"));
    Print("Trading Hours: ", (tradingHoursRestricted ?
          StringFormat("%02d:00-%02d:00 (server time)", TradingStartHour, TradingEndHour) :
          "no restriction"));
    Print("Profit Close Window: ", (profitCloseWindowEnabled && ProfitCloseTargetPips > 0 ?
          StringFormat("%02d:00-%02d:00 (server time), closes a basket at %d+ pips", ProfitCloseStartHour, ProfitCloseEndHour, ProfitCloseTargetPips) :
          "disabled"));
    Print("Basket TP: ", (BasketTakeProfitPips > 0 ? IntegerToString(BasketTakeProfitPips) + " pips" : "disabled"),
          "  Basket SL: ", (BasketStopLossPips > 0 ? IntegerToString(BasketStopLossPips) + " pips" : "disabled"));
    Print("Buy Basket: ", (BuyOpenNew ? "open new" : "close-only"),
          " Upper Limit: ", (buyUpperLimitInt > 0 ? DoubleToString(BuyUpperLimitPrice, symbolDigits) : "none"),
          " Entry Distance Below Reference: ", (buyEntryDistancePrice == 0 ? "at/below reference price" :
          (buyEntryDistancePrice > 0 ? IntegerToString(BuyEntryDistancePips) + " pips" : IntegerToString(-BuyEntryDistancePips) + " pips above reference price allowed")));
    Print("Sell Basket: ", (SellOpenNew ? "open new" : "close-only"),
          " Lower Limit: ", (sellLowerLimitInt > 0 ? DoubleToString(SellLowerLimitPrice, symbolDigits) : "none"),
          " Entry Distance Above Reference: ", (sellEntryDistancePrice == 0 ? "at/above reference price" :
          (sellEntryDistancePrice > 0 ? IntegerToString(SellEntryDistancePips) + " pips" : IntegerToString(-SellEntryDistancePips) + " pips below reference price allowed")));

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

    if(MaxGridLevels < 0 || BuyMaxGridLevels < 0 || SellMaxGridLevels < 0)
    {
        Print("Error: Max grid levels values must be non-negative");
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

    if(ProfitCloseTargetPips < 0)
    {
        Print("Error: Profit close target must be non-negative");
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
    Print("DailyStraddleBasket EA Terminated");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    UpdateReference();
    ManageBasket(true);
    ManageBasket(false);
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
//| completed bar whose close lines up with ReferenceHour:00: today's |
//| if that hour has already passed, otherwise yesterday's. Assumes  |
//| one PERIOD_CURRENT bar == one hour (H1 chart, enforced in OnInit).|
//+------------------------------------------------------------------+
int GetLastReferenceShift()
{
    int shift = GetHour(iTime(_Symbol, PERIOD_CURRENT, 0)) - ReferenceHour + 1;
    if(shift <= 0) shift += 24;
    return shift;
}

//+------------------------------------------------------------------+
//| Capture the close of the bar at the given shift into               |
//| referencePriceInt. Leaves the previous value untouched if that    |
//| bar's history isn't available yet (referenceReady stays false     |
//| until the first successful capture, so callers keep retrying).    |
//+------------------------------------------------------------------+
void CaptureReferencePrice(int shift)
{
    double close = iClose(_Symbol, PERIOD_CURRENT, shift);
    if(close <= 0) return;

    referencePriceInt = PriceToInt(close);
    referenceReady = true;

    Print("Reference price captured for ", TimeToString(iTime(_Symbol, PERIOD_CURRENT, shift - 1), TIME_DATE | TIME_MINUTES));
    Print("Reference price: ", DoubleToString(referencePriceInt * pointValue, symbolDigits));
}

//+------------------------------------------------------------------+
//| Keep referencePriceInt up to date. buyEnteredToday /               |
//| sellEnteredToday still reset on calendar date change (their own   |
//| once-per-day gate). The reference price itself never resets to    |
//| an empty state: on first run it immediately catches up with the  |
//| most recent ReferenceHour bar, and afterwards is only re-checked  |
//| on each new bar, refreshing it whenever that bar's hour equals     |
//| ReferenceHour.                                                     |
//+------------------------------------------------------------------+
void UpdateReference()
{
    MqlDateTime now;
    TimeToStruct(TimeCurrent(), now);

    if(now.day != referenceDay || now.mon != referenceMonth || now.year != referenceYear)
    {
        buyEnteredToday  = false;
        sellEnteredToday = false;
        referenceDay   = now.day;
        referenceMonth = now.mon;
        referenceYear  = now.year;
    }

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

    CaptureReferencePrice(1);
}

//+------------------------------------------------------------------+
//| Collect open position count, floating profit, volume-weighted    |
//| average pips profit, and the extreme open price (lowest for buy, |
//| highest for sell) of a basket. markPriceInt must be the side a   |
//| position of this direction would actually close at (Bid for buy, |
//| Ask for sell) - not the side used to open a new one - so          |
//| pipsProfit matches what CloseBasket() will actually realize.      |
//+------------------------------------------------------------------+
void GetBasketStatus(bool isBuy, int markPriceInt, int &count, double &profit, int &extremePriceInt, double &pipsProfit)
{
    double weightedPriceSum = 0;
    double totalVolume = 0;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket <= 0) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

        ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        if(isBuy != (type == POSITION_TYPE_BUY)) continue;

        count++;
        profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

        double volume = PositionGetDouble(POSITION_VOLUME);
        int openPrice = PriceToInt(PositionGetDouble(POSITION_PRICE_OPEN));
        int diffInt = isBuy ? (markPriceInt - openPrice) : (openPrice - markPriceInt);
        weightedPriceSum += diffInt * volume;
        totalVolume += volume;

        if(isBuy) { if(openPrice < extremePriceInt) extremePriceInt = openPrice; }
        else      { if(openPrice > extremePriceInt) extremePriceInt = openPrice; }
    }

    pipsProfit = totalVolume > 0 ? (weightedPriceSum / totalVolume) / pipFactor : 0;
}

//+------------------------------------------------------------------+
//| Manage a basket: open the initial position, add grid levels as   |
//| price moves further against the basket, and close the whole      |
//| basket once the take profit / stop loss target is reached        |
//+------------------------------------------------------------------+
void ManageBasket(bool isBuy)
{
    int    count = 0;
    double profit = 0;
    double pipsProfit = 0;
    int    extremePriceInt = isBuy ? 999999999 : 0;

    int currentPrice = isBuy ? PriceToInt(SymbolInfoDouble(_Symbol, SYMBOL_ASK))
                              : PriceToInt(SymbolInfoDouble(_Symbol, SYMBOL_BID));
    int markPrice = isBuy ? PriceToInt(SymbolInfoDouble(_Symbol, SYMBOL_BID))
                           : PriceToInt(SymbolInfoDouble(_Symbol, SYMBOL_ASK));

    GetBasketStatus(isBuy, markPrice, count, profit, extremePriceInt, pipsProfit);

    // A close-only side never starts a new basket; an already-open one is still
    // managed (grid adds + TP/SL) so it can wind down.
    bool openNew = isBuy ? BuyOpenNew : SellOpenNew;

    if(count == 0)
    {
        if(openNew && IsWithinTradingHours() && IsWithinLimit(isBuy, currentPrice) && IsSpreadAllowed() && IsReferenceEntryAllowed(isBuy) && HasReachedEntryDistance(isBuy, currentPrice))
        {
            if(OpenGridOrder(isBuy, 0)) MarkEnteredToday(isBuy);
        }
        return;
    }

    if(IsWithinTradingHours() &&
       ((BasketTakeProfitPips > 0 && pipsProfit >= BasketTakeProfitPips) ||
        (BasketStopLossPips   > 0 && pipsProfit <= -BasketStopLossPips)))
    {
        CloseBasket(isBuy, profit, pipsProfit);
        return;
    }

    if(IsWithinProfitCloseWindow() && ProfitCloseTargetPips > 0 && pipsProfit >= ProfitCloseTargetPips)
    {
        CloseBasket(isBuy, profit, pipsProfit);
        return;
    }

    int maxLevels = GetMaxGridLevels(isBuy);
    if(maxLevels > 0 && count >= maxLevels) return;

    int stepPrice = CalculateGridStepPrice(count);
    bool triggered = isBuy ? (currentPrice <= extremePriceInt - stepPrice)
                            : (currentPrice >= extremePriceInt + stepPrice);

    if(triggered && IsWithinTradingHours() && IsSpreadAllowed() && IsWithinReferenceDistance(isBuy, currentPrice))
    {
        OpenGridOrder(isBuy, count);
    }
}

//+------------------------------------------------------------------+
//| Nanpin stop-distance filter: once price has moved more than      |
//| ReferenceMaxDistancePips away from this side's entry basis       |
//| (either direction), grid-level additions are suspended - the     |
//| basket is still monitored for TP/SL and the level-0 entry is     |
//| unaffected. The entry basis is the reference price adjusted by   |
//| this side's entry distance - referencePriceInt - buyEntryDistancePrice |
//| for buy, referencePriceInt + sellEntryDistancePrice for sell -   |
//| i.e. the same price level HasReachedEntryDistance() requires     |
//| price to have reached before level 0 may open. 0 = no limit.     |
//+------------------------------------------------------------------+
bool IsWithinReferenceDistance(bool isBuy, int currentPriceInt)
{
    if(referenceMaxDistancePrice <= 0) return true;
    if(!referenceReady) return true;

    int distancePrice = isBuy ? buyEntryDistancePrice : sellEntryDistancePrice;
    int basePriceInt = isBuy ? (referencePriceInt - distancePrice) : (referencePriceInt + distancePrice);
    return MathAbs(currentPriceInt - basePriceInt) <= referenceMaxDistancePrice;
}

//+------------------------------------------------------------------+
//| Fade entry-distance gate for a new basket's level-0 position:    |
//| requires price to have already moved BuyEntryDistancePips below  |
//| (buy) / SellEntryDistancePips above (sell) today's reference      |
//| price before that side may open - a distance of 0 requires price |
//| to be at or beyond the reference price itself (buy: at/below it, |
//| sell: at/above it). A negative distance relaxes the gate so that |
//| side may open before price reaches the reference (buy: still up  |
//| to |distance| pips above it; sell: still up to |distance| pips   |
//| below it). Only applies to the position that starts a new        |
//| basket, not grid-level additions.                                 |
//+------------------------------------------------------------------+
bool HasReachedEntryDistance(bool isBuy, int currentPriceInt)
{
    if(!referenceReady) return false;

    int distancePrice = isBuy ? buyEntryDistancePrice : sellEntryDistancePrice;
    return isBuy ? (currentPriceInt <= referencePriceInt - distancePrice)
                 : (currentPriceInt >= referencePriceInt + distancePrice);
}

//+------------------------------------------------------------------+
//| Resolve the effective max grid levels for a basket: the          |
//| per-direction override (BuyMaxGridLevels / SellMaxGridLevels)    |
//| when it is 1 or more, otherwise the common MaxGridLevels         |
//| (0 = unlimited).                                                 |
//+------------------------------------------------------------------+
int GetMaxGridLevels(bool isBuy)
{
    int perDir = isBuy ? BuyMaxGridLevels : SellMaxGridLevels;
    return perDir > 0 ? perDir : MaxGridLevels;
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
//| Entry gate for a new basket's level-0 position: today's          |
//| ReferenceHour close must already be captured, and this side must |
//| not have opened a basket off it yet today. Both buy and sell use |
//| the same reference, so both sides open together once it is       |
//| captured. Only applies to the position that starts a new basket, |
//| not grid-level additions.                                        |
//+------------------------------------------------------------------+
bool IsReferenceEntryAllowed(bool isBuy)
{
    if(!referenceReady) return false;
    return isBuy ? !buyEnteredToday : !sellEnteredToday;
}

//+------------------------------------------------------------------+
//| Mark this side as having opened its basket off today's reference |
//+------------------------------------------------------------------+
void MarkEnteredToday(bool isBuy)
{
    if(isBuy) buyEnteredToday  = true;
    else      sellEnteredToday = true;
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
//| that closes a basket once it reaches ProfitCloseTargetPips,       |
//| independent of BasketTakeProfitPips and TradingStartHour/         |
//| TradingEndHour.                                                    |
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
//| Open a market order for the next grid level of a basket          |
//+------------------------------------------------------------------+
bool OpenGridOrder(bool isBuy, int level)
{
    double lot = CalculateLotSize(level);
    string comment = StringFormat("Basket L%d", level);

    bool result = isBuy ? trade.Buy(lot, _Symbol, 0, 0, 0, comment)
                         : trade.Sell(lot, _Symbol, 0, 0, 0, comment);

    if(result)
        Print((isBuy ? "Buy" : "Sell"), " grid order opened: Level ", level, " Lot ", DoubleToString(lot, 2));
    else
        Print((isBuy ? "Buy" : "Sell"), " grid order failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());

    return result;
}

//+------------------------------------------------------------------+
//| Close every position belonging to a basket                       |
//+------------------------------------------------------------------+
void CloseBasket(bool isBuy, double profit, double pipsProfit)
{
    double totalLots = 0;
    int    closedCount = 0;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket <= 0) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

        ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        if(isBuy != (type == POSITION_TYPE_BUY)) continue;

        totalLots += PositionGetDouble(POSITION_VOLUME);
        if(trade.PositionClose(ticket)) closedCount++;
    }

    Print((isBuy ? "Buy" : "Sell"), " basket closed: ", closedCount, " position(s), ",
          DoubleToString(totalLots, 2), " lots, Profit ", DoubleToString(profit, 2),
          " (", DoubleToString(pipsProfit, 1), " pips)");
}
