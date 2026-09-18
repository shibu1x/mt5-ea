//+------------------------------------------------------------------+
//|                                            CloseOnlyBasket.mq5   |
//|          Close-only Grid/Basket Manager for Existing Positions   |
//+------------------------------------------------------------------+
#property copyright "Grid Trading EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

// Input Parameters
input group "=== Basic Settings ==="
input double   LotSize = 0.01;              // Initial Lot Size (base for grid-add sizing; unused if no grid add ever fires)
input double   LotMultiplier = 1.5;         // Lot Multiplier per Grid Level (1.0 = fixed lot)
input int      GridStepPips = 10;           // Grid Step (pips)
input double   GridStepMultiplier = 1.2;    // Grid Step Multiplier per Grid Level (1.0 = fixed step)
input int      MaxGridLevels = 10;          // Max Grid Levels (0 = unlimited)
input int      BasketTakeProfitPips = 10;   // Basket Take Profit (pips, volume-weighted avg, 0 = disabled)
input int      BasketStopLossPips = 0;      // Basket Stop Loss (pips, volume-weighted avg, 0 = disabled)
input double   MaxSpreadPips = 1.1;         // Max Spread to Allow Grid Adds (pips, 0 = no limit)
input int      MagicNumber = 8020;          // Magic Number (only positions carrying this Magic are managed)

input group "=== Trading Hours ==="
input int      TradingStartHour = 0;        // Trading Start Hour (server time, 0-23)
input int      TradingEndHour = 0;          // Trading End Hour (server time, 0-23; start == end means no restriction)

input group "=== Rapid Nanpin Brake ==="
input int      RapidAddMaxCount = 0;        // Grid adds within the window that trip the brake (0 = disabled)
input int      RapidAddWindowMinutes = 30;  // Rolling window for counting recent grid adds (minutes)
input int      RapidAddPauseHours = 1;       // Pause further grid adds this long once the brake trips (hours)

// Global Variables
CTrade trade;
int gridStepPrice;
double pointValue;
double cachedLotSize;
int symbolDigits;
int maxSpreadPrice;
int pipFactor;
bool tradingHoursRestricted;
int tradingStartMinutes;
int tradingEndMinutes;
int rapidAddWindowSeconds;
int rapidAddPauseSeconds;
datetime buyGridAddTimes[];
datetime sellGridAddTimes[];
datetime buyGridAddPauseUntil  = 0;
datetime sellGridAddPauseUntil = 0;

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
    maxSpreadPrice = PipsToInt(MaxSpreadPips);

    tradingStartMinutes  = TradingStartHour * 60;
    tradingEndMinutes    = TradingEndHour * 60;
    tradingHoursRestricted = (tradingStartMinutes != tradingEndMinutes);

    rapidAddWindowSeconds = RapidAddWindowMinutes * 60;
    rapidAddPauseSeconds  = RapidAddPauseHours * 3600;

    Print("=== CloseOnlyBasket EA Initialization ===");
    Print("Mode: close-only - never opens a new position, only manages positions already");
    Print("      carrying Magic ", MagicNumber, " (grid adds + basket TP/SL exit)");
    Print("Grid Step: ", GridStepPips, " pips (", DoubleToString(gridStepPrice * pointValue, symbolDigits),
          ")  Step Multiplier: ", GridStepMultiplier);
    Print("Grid-add Lot base: ", DoubleToString(cachedLotSize, 2),
          "  Multiplier: ", LotMultiplier,
          "  Max Levels: ", (MaxGridLevels == 0 ? "unlimited" : IntegerToString(MaxGridLevels)));
    Print("Max Spread: ", (maxSpreadPrice > 0 ? (DoubleToString(MaxSpreadPips, 1) + " pips") : "no limit"));
    Print("Trading Hours: ", (tradingHoursRestricted ?
          StringFormat("%02d:00-%02d:00 (server time)", TradingStartHour, TradingEndHour) :
          "no restriction"));
    Print("Rapid Nanpin Brake: ", (RapidAddMaxCount > 0 ?
          StringFormat("%d adds / %d min -> pause %d h", RapidAddMaxCount, RapidAddWindowMinutes, RapidAddPauseHours) :
          "disabled"));
    Print("Basket TP: ", (BasketTakeProfitPips > 0 ? IntegerToString(BasketTakeProfitPips) + " pips" : "disabled"),
          "  Basket SL: ", (BasketStopLossPips > 0 ? IntegerToString(BasketStopLossPips) + " pips" : "disabled"));

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

    if(MaxGridLevels < 0)
    {
        Print("Error: Max grid levels must be non-negative");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(TradingStartHour < 0 || TradingStartHour > 23 || TradingEndHour < 0 || TradingEndHour > 23)
    {
        Print("Error: Trading hour values must be within 0-23");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(RapidAddMaxCount < 0 || RapidAddWindowMinutes < 0 || RapidAddPauseHours < 0)
    {
        Print("Error: Rapid nanpin brake values must be non-negative");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(RapidAddMaxCount > 0 && RapidAddWindowMinutes <= 0)
    {
        Print("Error: Rapid nanpin window must be positive when the brake is enabled");
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
    Print("CloseOnlyBasket EA Terminated");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    ManageBasket(true);
    ManageBasket(false);
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
//| Manage a basket of pre-existing positions (carrying MagicNumber): |
//| never opens a new position, only adds grid levels as price moves  |
//| further against the basket and closes the whole basket once the   |
//| take profit / stop loss target is reached. A basket with count == |
//| 0 has nothing to manage until a position carrying MagicNumber is  |
//| opened by some other means (manual trade, script, etc.).          |
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

    if(count == 0)
    {
        // Basket is flat: forget any rapid-nanpin burst history for this side.
        ResetRapidAddTracking(isBuy);
        return;
    }

    if(IsWithinTradingHours() &&
       ((BasketTakeProfitPips > 0 && pipsProfit >= BasketTakeProfitPips) ||
        (BasketStopLossPips   > 0 && pipsProfit <= -BasketStopLossPips)))
    {
        CloseBasket(isBuy, profit, pipsProfit);
        return;
    }

    if(MaxGridLevels > 0 && count >= MaxGridLevels) return;

    int stepPrice = CalculateGridStepPrice(count);
    bool triggered = isBuy ? (currentPrice <= extremePriceInt - stepPrice)
                            : (currentPrice >= extremePriceInt + stepPrice);

    if(triggered && IsWithinTradingHours() && IsSpreadAllowed() && CanAddGridLevel(isBuy))
    {
        if(OpenGridOrder(isBuy, count)) RegisterGridAdd(isBuy);
    }
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
//| Check whether the current spread allows grid adds                 |
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
//| both grid adds and basket TP/SL closing                          |
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
//| Rapid-nanpin brake: when grid adds (nanpin) on one side pile up  |
//| too fast — RapidAddMaxCount adds inside RapidAddWindowMinutes —  |
//| further adds on that side are suspended for RapidAddPauseHours.  |
//| Tracking is per direction and is cleared when the basket goes    |
//| flat (count == 0). RapidAddMaxCount = 0 disables the brake.      |
//+------------------------------------------------------------------+
bool CanAddGridLevel(bool isBuy)
{
    if(RapidAddMaxCount <= 0) return true;

    datetime now = TimeCurrent();
    datetime pauseUntil = isBuy ? buyGridAddPauseUntil : sellGridAddPauseUntil;
    if(pauseUntil > 0)
    {
        if(now < pauseUntil) return false;
        // Cooldown elapsed: lift the pause and forget the burst that caused it.
        if(isBuy) { buyGridAddPauseUntil = 0;  ArrayResize(buyGridAddTimes, 0); }
        else      { sellGridAddPauseUntil = 0; ArrayResize(sellGridAddTimes, 0); }
    }
    return true;
}

//+------------------------------------------------------------------+
//| Record a successful grid add; if the number of adds still inside |
//| the rolling window has reached RapidAddMaxCount, engage the      |
//| rapid-nanpin pause for that side.                                |
//+------------------------------------------------------------------+
void RegisterGridAdd(bool isBuy)
{
    if(RapidAddMaxCount <= 0) return;

    datetime now = TimeCurrent();
    datetime cutoff = now - rapidAddWindowSeconds;

    int recent = isBuy ? AppendAndTrim(buyGridAddTimes, now, cutoff)
                        : AppendAndTrim(sellGridAddTimes, now, cutoff);

    if(recent >= RapidAddMaxCount)
    {
        datetime pauseUntil = now + rapidAddPauseSeconds;
        if(isBuy) buyGridAddPauseUntil  = pauseUntil;
        else      sellGridAddPauseUntil = pauseUntil;

        Print((isBuy ? "Buy" : "Sell"), " rapid-nanpin brake engaged: ", recent,
              " grid adds within ", RapidAddWindowMinutes, " min - pausing adds until ",
              TimeToString(pauseUntil, TIME_DATE | TIME_MINUTES));
    }
}

//+------------------------------------------------------------------+
//| Append a timestamp, drop entries older than the cutoff, and      |
//| return how many remain in the window                             |
//+------------------------------------------------------------------+
int AppendAndTrim(datetime &times[], datetime stamp, datetime cutoff)
{
    int n = ArraySize(times);
    ArrayResize(times, n + 1);
    times[n] = stamp;

    int keep = 0;
    for(int i = 0; i < ArraySize(times); i++)
        if(times[i] >= cutoff) times[keep++] = times[i];
    ArrayResize(times, keep);

    return keep;
}

//+------------------------------------------------------------------+
//| Clear the rapid-nanpin tracking for a side (basket is flat)      |
//+------------------------------------------------------------------+
void ResetRapidAddTracking(bool isBuy)
{
    if(isBuy) { ArrayResize(buyGridAddTimes, 0);  buyGridAddPauseUntil  = 0; }
    else      { ArrayResize(sellGridAddTimes, 0); sellGridAddPauseUntil = 0; }
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
