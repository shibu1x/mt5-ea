//+------------------------------------------------------------------+
//|                                               NewsFadeBasket.mq5 |
//|   Continuous dual-basket mean-reversion grid with a news-release  |
//|   entry model: the reference is a live Bid snapshot taken shortly |
//|   before a scheduled news release (EventHour:EventMinute, server  |
//|   time, recurring daily), and a new basket's level-0 entry may    |
//|   only open while now is within DetectionWindowMinutes after that |
//|   event time (and off today's fresh snapshot). A buy basket opens |
//|   when price is MoveThresholdPips below the reference, a sell     |
//|   basket the same distance above; each basket adds grid/martingale|
//|   levels against adverse moves and is closed as a whole once its  |
//|   volume-weighted average pips profit reaches BasketTakeProfitPips|
//|   (or the loss reaches -BasketStopLossPips) - the same exit       |
//|   No per-order TP/SL. The snapshot reference and detection window |
//|   only gate level-0 entry; an open basket needs no session state. |
//|   OpenMode (buy&sell / buy only / sell only / none) selects which |
//|   side(s) may open a new level-0 basket, leaving grid adds and    |
//|   the basket exit unaffected.                                     |
//+------------------------------------------------------------------+
#property copyright "Grid Trading EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

enum ENUM_OPEN_MODE
{
    OPEN_MODE_BOTH      = 0,  // Buy & Sell
    OPEN_MODE_BUY_ONLY  = 1,  // Buy only
    OPEN_MODE_SELL_ONLY = 2,  // Sell only
    OPEN_MODE_NONE      = 3   // None (close only)
};

// Input Parameters
input group "=== Reference Snapshot Settings ==="
input int      EventHour = 15;              // Event Hour (server time, 0-23, recurs daily)
input int      EventMinute = 30;            // Event Minute (server time, 0-59)
input int      PreEventSnapshotMinutes = 5; // Minutes Before Event Time to Snapshot the Pre-Release Price
input int      DetectionWindowMinutes = 30; // Window After Event Time in Which New Fade Baskets May Open (minutes)
input int      MoveThresholdPips = 20;      // Move From Reference to Open a Fade Basket (pips)

input group "=== Basic Settings ==="
input double   LotSize = 0.01;              // Initial Lot Size
input double   LotMultiplier = 1.5;         // Lot Multiplier per Grid Level (1.0 = fixed lot)
input int      GridStepPips = 10;           // Grid Step Against the Basket (pips)
input double   GridStepMultiplier = 1.2;    // Grid Step Multiplier per Level (1.0 = fixed step)
input int      MaxGridLevels = 10;          // Max Grid Levels per Basket
input int      BasketTakeProfitPips = 20;   // Basket Take Profit (pips, volume-weighted avg, 0 = disabled)
input int      TakeProfitStepPips = 0;      // Reduce Take Profit by This Much per Nanpin Add (pips, 0 = no decay)
input int      BasketTakeProfitMinPips = 2; // Take Profit Floor After Decay (pips)
input int      BasketStopLossPips = 500;    // Basket Stop Loss (pips, volume-weighted avg, 0 = disabled)
input double   MaxSpreadPips = 1.1;         // Max Spread to Allow New Entries (pips, 0 = no limit)
input ENUM_OPEN_MODE OpenMode = OPEN_MODE_BOTH; // Open New Fade Baskets (which side(s) may start a new basket)
input int      MagicNumber = 9001;          // Magic Number

// Global Variables
CTrade trade;
int      symbolDigits;
int      pipFactor;
double   pointValue;
int      moveThresholdPrice;
int      maxSpreadPrice;
int      gridStepPrice;
double   cachedLotSize;

datetime currentEventTime;   // today's computed event datetime; marks which day's snapshot is tracked
int      referencePriceInt;  // pre-release Bid snapshot (integer price); 0 until first captured
bool     capturedToday;      // whether today's snapshot attempt is done (captured or its window passed)
bool     referenceFresh;     // whether referencePriceInt is from TODAY's snapshot (gates new level-0 entries)

// referencePriceInt (a live pre-release Bid capture that, unlike a bar-open
// reference, cannot be recomputed from history) plus capturedToday /
// referenceFresh / currentEventTime are all the EA's session state, and every
// one of them serves only the level-0 entry trigger. An open basket is driven
// entirely by its own positions - direction is the ManageBasket argument, the
// exit is its volume-weighted pips P/L - so a restart with a basket open is
// safe with no recovery code: the basket keeps being managed even before the
// day's snapshot is (re-)taken.

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
//| Compute today's event datetime from EventHour/EventMinute        |
//+------------------------------------------------------------------+
datetime ComputeEventTime()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    dt.hour = EventHour;
    dt.min  = EventMinute;
    dt.sec  = 0;
    return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| Refresh referencePriceInt once per day: shortly before today's   |
//| event time (PreEventSnapshotMinutes earlier) capture the current |
//| Bid as the pre-release rate and set referenceFresh. If that      |
//| window has already passed when this first runs today (EA started |
//| late, or restarted after the release), today's snapshot is       |
//| skipped and referenceFresh stays false, so no NEW basket opens   |
//| today - but any already-open basket keeps being managed off its  |
//| own volume-weighted pips P/L, so a restart never leaves one      |
//| unattended. referencePriceInt only ever gates level-0 entry.     |
//+------------------------------------------------------------------+
void UpdateReference()
{
    datetime todayEventTime = ComputeEventTime();
    if(todayEventTime != currentEventTime)
    {
        currentEventTime = todayEventTime;
        capturedToday   = false;
        referenceFresh  = false;
        Print("Tracking today's snapshot for the event at ",
              TimeToString(currentEventTime, TIME_DATE | TIME_MINUTES));
    }

    if(capturedToday) return;

    datetime now = TimeCurrent();
    datetime snapshotTime = currentEventTime - PreEventSnapshotMinutes * 60;

    if(now < snapshotTime) return;

    if(now >= currentEventTime)
    {
        capturedToday = true;
        Print("Missed today's pre-release snapshot window; no new baskets today");
        return;
    }

    referencePriceInt = PriceToInt(SymbolInfoDouble(_Symbol, SYMBOL_BID));
    capturedToday  = true;
    referenceFresh = true;
    Print("Pre-release reference captured: ", DoubleToString(referencePriceInt * pointValue, symbolDigits));
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(10);
    trade.SetTypeFilling(ORDER_FILLING_FOK);

    pointValue   = _Point;
    symbolDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    pipFactor    = (symbolDigits == 3 || symbolDigits == 5) ? 10 : 100;
    cachedLotSize = MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
                    MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), LotSize));
    moveThresholdPrice = PipsToInt(MoveThresholdPips);
    maxSpreadPrice     = PipsToInt(MaxSpreadPips);
    gridStepPrice      = PipsToInt(GridStepPips);

    Print("=== NewsFadeBasket EA Initialization ===");
    Print("Event Time: ", StringFormat("%02d:%02d", EventHour, EventMinute),
          " (server time, recurs daily)  Snapshot: ", PreEventSnapshotMinutes,
          " min before  Detection Window: ", DetectionWindowMinutes, " min after");
    Print("Move Threshold: ", MoveThresholdPips, " pips  Initial Lot: ", cachedLotSize);
    Print("Max Spread: ", (maxSpreadPrice > 0 ? (DoubleToString(MaxSpreadPips, 1) + " pips") : "no limit"));
    Print("Basket TP: ", (BasketTakeProfitPips > 0 ? IntegerToString(BasketTakeProfitPips) + " pips (volume-weighted avg)" : "disabled"),
          (BasketTakeProfitPips > 0 && TakeProfitStepPips > 0 ?
           StringFormat(" (- %d pips per nanpin add, floor %d pips)", TakeProfitStepPips, BasketTakeProfitMinPips) : ""),
          "  Basket SL: ", (BasketStopLossPips > 0 ? IntegerToString(BasketStopLossPips) + " pips (volume-weighted avg)" : "disabled"));
    Print("Grid Step: ", GridStepPips, " pips  Step Multiplier: ", GridStepMultiplier,
          "  Lot Multiplier: ", LotMultiplier,
          "  Max Levels: ", MaxGridLevels);
    Print("Open Mode: ", EnumToString(OpenMode));

    // OPEN_MODE_NONE (and either single-side mode) is a valid configuration:
    // a pure wind-down of open baskets with no new entries is not rejected here.

    if(EventHour < 0 || EventHour > 23 || EventMinute < 0 || EventMinute > 59)
    {
        Print("Error: Event hour must be 0-23 and event minute must be 0-59");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(PreEventSnapshotMinutes <= 0)
    {
        Print("Error: Pre-event snapshot minutes must be positive");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(DetectionWindowMinutes <= 0)
    {
        Print("Error: Detection window minutes must be positive");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(MoveThresholdPips <= 0)
    {
        Print("Error: Move threshold pips must be positive");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(BasketTakeProfitPips < 0)
    {
        Print("Error: Basket take profit pips cannot be negative");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(BasketStopLossPips < 0)
    {
        Print("Error: Basket stop loss pips cannot be negative");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(GridStepPips <= 0)
    {
        Print("Error: Grid step pips must be positive");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(GridStepMultiplier <= 0)
    {
        Print("Error: Grid step multiplier must be positive");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(LotMultiplier <= 0)
    {
        Print("Error: Lot multiplier must be positive");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(MaxGridLevels <= 0)
    {
        Print("Error: Max grid levels must be positive");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(TakeProfitStepPips < 0)
    {
        Print("Error: Take profit step must be non-negative");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(BasketTakeProfitMinPips < 0)
    {
        Print("Error: Take profit floor must be non-negative");
        return INIT_PARAMETERS_INCORRECT;
    }

    referencePriceInt = 0;
    currentEventTime  = 0;
    capturedToday     = false;
    referenceFresh    = false;
    UpdateReference();

    Print("Initialization Complete");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("NewsFadeBasket EA Terminated");
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
//| Return the ticket of the position at loop index i when it        |
//| belongs to this basket (this symbol, this magic, the given       |
//| direction), else 0. PositionGetTicket() has already selected it  |
//| as the current position, so callers can read its fields.         |
//+------------------------------------------------------------------+
ulong GetBasketPositionTicket(int i, bool isBuy)
{
    ulong ticket = PositionGetTicket(i);
    if(ticket <= 0) return 0;
    if(PositionGetString(POSITION_SYMBOL) != _Symbol) return 0;
    if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) return 0;
    if(isBuy != (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)) return 0;
    return ticket;
}

//+------------------------------------------------------------------+
//| Collect open position count, the extreme open price (lowest for  |
//| buy, highest for sell), and the basket's volume-weighted average |
//| pips profit - Σ((markPrice - openPrice) x direction x volume) /  |
//| Σvolume, in pips. markPriceInt must be the side a position of    |
//| this direction would actually close at (Bid for buy, Ask for     |
//| sell) - not the side used to open a new one - so pipsProfit      |
//| matches what CloseBasket() will actually realize. No account-    |
//| currency P/L is tracked.                                         |
//+------------------------------------------------------------------+
void GetBasketStatus(bool isBuy, int markPriceInt, int &count, int &extremePriceInt, double &pipsProfit)
{
    double weightedPriceSum = 0;
    double totalVolume = 0;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(GetBasketPositionTicket(i, isBuy) == 0) continue;

        count++;

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
//| Whether now is inside the daily window in which a new fade basket |
//| may open: [currentEventTime, currentEventTime +                   |
//| DetectionWindowMinutes]. Only the level-0 entry is gated by this; |
//| grid adds to an existing basket and the basket-P/L exit run any   |
//| time, so a basket opened late in the window is still managed to   |
//| completion afterwards.                                            |
//+------------------------------------------------------------------+
bool IsWithinDetectionWindow()
{
    datetime now = TimeCurrent();
    return now >= currentEventTime &&
           now <= currentEventTime + (datetime)(DetectionWindowMinutes * 60);
}

//+------------------------------------------------------------------+
//| Manage one direction's basket: open level 0 once price has moved  |
//| MoveThresholdPips away from the reference (only while OpenMode    |
//| allows this side to open, off a fresh snapshot, and within the    |
//| daily detection window), add grid/martingale levels while price   |
//| keeps moving further against it, and close the whole basket once  |
//| its volume-weighted average pips profit reaches                   |
//| BasketTakeProfitPips or its loss reaches BasketStopLossPips. With  |
//| no basket open the check is only the level-0 trigger, so within   |
//| the window the basket re-opens on each fresh excursion.           |
//+------------------------------------------------------------------+
void ManageBasket(bool isBuy)
{
    int    count = 0;
    double pipsProfit = 0;
    int    extremePriceInt = isBuy ? 999999999 : 0;

    int currentPriceInt = isBuy ? PriceToInt(SymbolInfoDouble(_Symbol, SYMBOL_ASK))
                                : PriceToInt(SymbolInfoDouble(_Symbol, SYMBOL_BID));
    int markPriceInt = isBuy ? PriceToInt(SymbolInfoDouble(_Symbol, SYMBOL_BID))
                             : PriceToInt(SymbolInfoDouble(_Symbol, SYMBOL_ASK));

    GetBasketStatus(isBuy, markPriceInt, count, extremePriceInt, pipsProfit);

    // A side excluded by OpenMode never starts a new basket; an already-open
    // one is still managed (grid adds + TP/SL) so it can wind down.
    bool openNew = isBuy ? (OpenMode == OPEN_MODE_BOTH || OpenMode == OPEN_MODE_BUY_ONLY)
                         : (OpenMode == OPEN_MODE_BOTH || OpenMode == OPEN_MODE_SELL_ONLY);

    if(count == 0)
    {
        if(!openNew || !referenceFresh) return;
        if(!IsWithinDetectionWindow()) return;

        bool trigger = isBuy ? (currentPriceInt <= referencePriceInt - moveThresholdPrice)
                             : (currentPriceInt >= referencePriceInt + moveThresholdPrice);
        if(trigger && IsSpreadAllowed())
            OpenGridLevel(isBuy, 0);
        return;
    }

    int effectiveTakeProfitPips = GetEffectiveTakeProfitPips(count);
    if((effectiveTakeProfitPips > 0 && pipsProfit >= effectiveTakeProfitPips) ||
       (BasketStopLossPips      > 0 && pipsProfit <= -BasketStopLossPips))
    {
        CloseBasket(isBuy, pipsProfit);
        return;
    }

    if(count >= MaxGridLevels) return;

    int stepPrice = CalculateGridStepPrice(count);
    bool triggered = isBuy ? (currentPriceInt <= extremePriceInt - stepPrice)
                           : (currentPriceInt >= extremePriceInt + stepPrice);

    if(triggered && IsSpreadAllowed())
        OpenGridLevel(isBuy, count);
}

//+------------------------------------------------------------------+
//| Resolve the basket take-profit target for the current position   |
//| count: BasketTakeProfitPips reduced by TakeProfitStepPips for     |
//| each nanpin (grid) add already made - level 0 itself doesn't      |
//| count, so the first reduction only applies once a level-1 add has |
//| happened - floored at BasketTakeProfitMinPips. TakeProfitStepPips |
//| == 0 keeps a flat BasketTakeProfitPips throughout, and            |
//| BasketTakeProfitPips == 0 stays disabled (returns 0) regardless   |
//| of count.                                                          |
//+------------------------------------------------------------------+
int GetEffectiveTakeProfitPips(int count)
{
    if(BasketTakeProfitPips <= 0) return 0;
    if(TakeProfitStepPips <= 0) return BasketTakeProfitPips;

    int nanpinCount = MathMax(count - 1, 0);
    int reduced = BasketTakeProfitPips - nanpinCount * TakeProfitStepPips;
    return MathMax(BasketTakeProfitMinPips, reduced);
}

//+------------------------------------------------------------------+
//| Calculate the grid step distance required to open the given       |
//| grid level, scaling by GridStepMultiplier per level                |
//+------------------------------------------------------------------+
int CalculateGridStepPrice(int level)
{
    return (int)MathRound(gridStepPrice * MathPow(GridStepMultiplier, MathMax(level - 1, 0)));
}

//+------------------------------------------------------------------+
//| Calculate lot size for a grid level, scaling by LotMultiplier    |
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
//| Open a market order for the given grid level of a basket. Level  |
//| 0 is the initial fade entry. No per-order TP/SL - the basket is  |
//| only ever closed as a whole on its volume-weighted pips P/L.     |
//+------------------------------------------------------------------+
void OpenGridLevel(bool isBuy, int level)
{
    double lot = CalculateLotSize(level);
    string comment = StringFormat("NewsFadeBasket %s L%d", (isBuy ? "Buy" : "Sell"), level);

    bool result = isBuy ? trade.Buy(lot, _Symbol, 0, 0, 0, comment)
                        : trade.Sell(lot, _Symbol, 0, 0, 0, comment);

    if(result)
    {
        Print((isBuy ? "Buy" : "Sell"), " grid level ", level, " opened - Lot ", DoubleToString(lot, 2));
    }
    else
    {
        Print((isBuy ? "Buy" : "Sell"), " grid level ", level, " order failed: ",
              trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
    }
}

//+------------------------------------------------------------------+
//| Close every position of one direction in the basket              |
//+------------------------------------------------------------------+
void CloseBasket(bool isBuy, double pipsProfit)
{
    double totalLots = 0;
    int    closedCount = 0;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = GetBasketPositionTicket(i, isBuy);
        if(ticket == 0) continue;

        totalLots += PositionGetDouble(POSITION_VOLUME);
        if(trade.PositionClose(ticket)) closedCount++;
    }

    Print((isBuy ? "Buy" : "Sell"), " basket closed: ", closedCount, " position(s), ",
          DoubleToString(totalLots, 2), " lots, ", DoubleToString(pipsProfit, 1), " pips");
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
