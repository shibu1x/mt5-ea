//+------------------------------------------------------------------+
//|                                                    FixedGrid.mq5 |
//|   Fixed-range grid EA centered on a manually configured price    |
//|   (CenterPrice, computed once at EA start, never re-centered).   |
//|   Buy and sell grids run independently and simultaneously, each  |
//|   gated only by its own enable switch (no trend filter).         |
//+------------------------------------------------------------------+
#property copyright "Grid Trading EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

// Input Parameters
input group "=== Basic Settings ==="
input double   CenterPrice = 0;             // Grid Center Price (required, > 0)
input int      GridStepPips = 5;            // Grid Step & TP (pips)
input int      GridRangePips = 200;         // Grid Range (pips from center, one side)
input double   LotSize = 0.01;              // Lot Size
input int      MagicNumber = 8070;          // Magic Number

input group "=== Trading Hours ==="
input int      TradingStartHour = 0;        // Trading Start Hour (server time, 0-23)
input int      TradingEndHour = 0;          // Trading End Hour (server time, 0-23; start == end means no restriction)

input group "=== Buy Settings ==="
input bool     BuyEnabled = true;           // Allow Buy Grid
input double   BuyUpperLimitPrice = 0;      // Buy Upper Limit Price (0 = no limit; buy levels only at or below)

input group "=== Sell Settings ==="
input bool     SellEnabled = true;          // Allow Sell Grid
input double   SellLowerLimitPrice = 0;     // Sell Lower Limit Price (0 = no limit; sell levels only at or above)

// Global Variables
CTrade trade;
int gridStepPrice;
double pointValue;
double cachedLotSize;
int totalBuyOrders = 0;
int totalSellOrders = 0;
int highestBuyPrice = 0;
int lowestBuyPrice = 0;
int highestSellPrice = 0;
int lowestSellPrice = 0;
datetime lastBarTime = 0;

// Grid boundaries (as integers), computed once at EA start from CenterPrice.
// The same [center - GridRangePips, center + GridRangePips] band is used for both buy and sell.
int gridLowerInt, gridUpperInt;

// Cached symbol info
int symbolDigits;

// Optional absolute price caps on where grid levels may be placed (0 = no cap):
// buy levels only at or below buyUpperLimitInt, sell levels only at or above sellLowerLimitInt.
int buyUpperLimitInt = 0;
int sellLowerLimitInt = 0;

// Trading hours restriction
bool tradingHoursRestricted;
int tradingStartMinutes;
int tradingEndMinutes;

//+------------------------------------------------------------------+
//| Convert pips to integer price units                              |
//+------------------------------------------------------------------+
int PipsToInt(int pips)
{
    return pips * ((symbolDigits == 3 || symbolDigits == 5) ? 10 : 100);
}

//+------------------------------------------------------------------+
//| Convert double price to integer price                            |
//+------------------------------------------------------------------+
int PriceToInt(double price)
{
    return (int)MathRound(price / pointValue);
}

//+------------------------------------------------------------------+
//| Convert integer price units to the nearest whole pips            |
//+------------------------------------------------------------------+
int IntToPips(int priceInt)
{
    return (int)MathRound(priceInt / (double)((symbolDigits == 3 || symbolDigits == 5) ? 10 : 100));
}

//+------------------------------------------------------------------+
//| Floor division (matches Python's // for a positive divisor)      |
//+------------------------------------------------------------------+
int FloorDiv(int a, int b)
{
    int q = a / b;
    if(a % b != 0 && ((a < 0) != (b < 0))) q--;
    return q;
}

//+------------------------------------------------------------------+
//| Round the center price (in pips) so it lands on a consistent     |
//| offset within each grid step, avoiding round-number overlaps     |
//+------------------------------------------------------------------+
int RoundCenterPips(int pips, int gridStep)
{
    if(gridStep == 5) return FloorDiv(pips, 5) * 5 + 2;
    if(gridStep == 4) return FloorDiv(pips, 4) * 4 + 1;
    if(gridStep == 3) return FloorDiv(pips, 3) * 3;
    return pips;
}

//+------------------------------------------------------------------+
//| Check whether the current server time falls within the allowed   |
//| trading hours window (wraps past midnight if start > end); gates |
//| placing new pending orders                                       |
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
//| Compute the fixed grid boundaries                                |
//| [CenterPrice - GridRangePips, CenterPrice + GridRangePips] once, |
//| from the manually configured CenterPrice. Both the buy and the   |
//| sell grid span this same band for the whole run.                 |
//+------------------------------------------------------------------+
bool ComputeGridBoundaries()
{
    int centerInt = PriceToInt(CenterPrice);
    centerInt = PipsToInt(RoundCenterPips(IntToPips(centerInt), GridStepPips));

    int rangeInt = PipsToInt(GridRangePips);
    gridLowerInt = centerInt - rangeInt;
    gridUpperInt = centerInt + rangeInt;

    if(gridLowerInt <= 0)
    {
        Print("Error: Calculated grid lower price is invalid (", DoubleToString(gridLowerInt * pointValue, symbolDigits), ")");
        return false;
    }

    Print("Grid Center Price (manual, rounded): ", DoubleToString(centerInt * pointValue, symbolDigits));
    Print("Grid Range: ", DoubleToString(gridLowerInt * pointValue, symbolDigits), " - ", DoubleToString(gridUpperInt * pointValue, symbolDigits), " (", GridRangePips, " pips each side)");

    return true;
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
    cachedLotSize = MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
                    MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), LotSize));
    gridStepPrice = PipsToInt(GridStepPips);

    tradingStartMinutes    = TradingStartHour * 60;
    tradingEndMinutes      = TradingEndHour * 60;
    tradingHoursRestricted = (tradingStartMinutes != tradingEndMinutes);

    buyUpperLimitInt  = (BuyUpperLimitPrice  > 0) ? PriceToInt(BuyUpperLimitPrice)  : 0;
    sellLowerLimitInt = (SellLowerLimitPrice > 0) ? PriceToInt(SellLowerLimitPrice) : 0;

    Print("=== FixedGrid EA Initialization ===");
    Print("Grid Step & TP: ", GridStepPips, " pips (", DoubleToString(gridStepPrice * pointValue, symbolDigits), ")");
    Print("Lot Size: ", cachedLotSize);
    Print("Trading Hours: ", (tradingHoursRestricted ?
          StringFormat("%02d:00-%02d:00 (server time)", TradingStartHour, TradingEndHour) :
          "no restriction"));
    Print("Direction: ", (BuyEnabled ? "buy " : ""), (SellEnabled ? "sell" : ""),
          (BuyEnabled || SellEnabled ? "" : "(none)"));
    Print("Buy Upper Limit Price: ", (buyUpperLimitInt > 0 ?
          DoubleToString(buyUpperLimitInt * pointValue, symbolDigits) : "no limit"));
    Print("Sell Lower Limit Price: ", (sellLowerLimitInt > 0 ?
          DoubleToString(sellLowerLimitInt * pointValue, symbolDigits) : "no limit"));

    if(CenterPrice <= 0)
    {
        Print("Error: Center price must be a positive value");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(GridRangePips < 0)
    {
        Print("Error: Grid range must be non-negative");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(BuyUpperLimitPrice < 0 || SellLowerLimitPrice < 0)
    {
        Print("Error: Buy upper / sell lower limit price must be non-negative");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(!BuyEnabled && !SellEnabled)
    {
        Print("Error: At least one direction (Buy or Sell) must be enabled");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(TradingStartHour < 0 || TradingStartHour > 23 || TradingEndHour < 0 || TradingEndHour > 23)
    {
        Print("Error: Trading hour values must be within 0-23");
        return INIT_PARAMETERS_INCORRECT;
    }

    lastBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(!ComputeGridBoundaries())
        return INIT_PARAMETERS_INCORRECT;

    Print("Initialization Complete");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("FixedGrid EA Terminated");
}

//+------------------------------------------------------------------+
//| Run grid management for each enabled side; a disabled side has   |
//| its pending orders pulled while its open positions are left to   |
//| reach their own take profit                                      |
//+------------------------------------------------------------------+
void RunGridManagement()
{
    UpdateGridStatus();

    bool runBuy  = BuyEnabled  && GridRangePips > 0;
    bool runSell = SellEnabled && GridRangePips > 0;

    if(!runBuy)  DeleteSideOrders(true);
    if(!runSell) DeleteSideOrders(false);

    if(runBuy)  ManageGrid(true);
    if(runSell) ManageGrid(false);
}

//+------------------------------------------------------------------+
//| Trade event handler                                              |
//+------------------------------------------------------------------+
void OnTrade()
{
    static int lastPositionCount = 0;
    int currentPositionCount = 0;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket <= 0) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
        currentPositionCount++;
    }

    if(lastPositionCount > currentPositionCount)
    {
        Print("Position Closed Detected - Executing Grid Update");
        RunGridManagement();
    }

    lastPositionCount = currentPositionCount;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(currentBarTime == lastBarTime) return;
    lastBarTime = currentBarTime;

    Print("Bar Updated");

    RunGridManagement();
}

//+------------------------------------------------------------------+
//| Update grid status                                               |
//+------------------------------------------------------------------+
void UpdateGridStatus()
{
    totalBuyOrders   = 0;
    totalSellOrders  = 0;
    highestBuyPrice  = 0;
    lowestBuyPrice   = 999999999;
    highestSellPrice = 0;
    lowestSellPrice  = 999999999;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket <= 0) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

        int openPrice = PriceToInt(PositionGetDouble(POSITION_PRICE_OPEN));
        ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

        if(type == POSITION_TYPE_BUY)
        {
            totalBuyOrders++;
            if(openPrice > highestBuyPrice) highestBuyPrice = openPrice;
            if(openPrice < lowestBuyPrice)  lowestBuyPrice  = openPrice;
        }
        else if(type == POSITION_TYPE_SELL)
        {
            totalSellOrders++;
            if(openPrice > highestSellPrice) highestSellPrice = openPrice;
            if(openPrice < lowestSellPrice)  lowestSellPrice  = openPrice;
        }
    }
}

//+------------------------------------------------------------------+
//| Manage grid (buy or sell)                                        |
//+------------------------------------------------------------------+
void ManageGrid(bool isBuy)
{
    int lowerInt = gridLowerInt;
    int upperInt = gridUpperInt;

    // Absolute price caps (0 = no cap): the grid ladder stays anchored to the
    // center-based levels, but levels outside the cap are neither placed nor kept.
    int placeLowerInt = lowerInt;
    int placeUpperInt = upperInt;
    if(isBuy && buyUpperLimitInt > 0 && buyUpperLimitInt < placeUpperInt)
        placeUpperInt = buyUpperLimitInt;
    if(!isBuy && sellLowerLimitInt > 0 && sellLowerLimitInt > placeLowerInt)
        placeLowerInt = sellLowerLimitInt;

    int currentPrice = isBuy ? PriceToInt(SymbolInfoDouble(_Symbol, SYMBOL_ASK))
                              : PriceToInt(SymbolInfoDouble(_Symbol, SYMBOL_BID));

    int gridPrice = isBuy ? upperInt : lowerInt;
    int step      = isBuy ? -gridStepPrice : gridStepPrice;

    bool tradingAllowed = IsWithinTradingHours();

    while(isBuy ? gridPrice >= lowerInt : gridPrice <= upperInt)
    {
        if(tradingAllowed && gridPrice >= placeLowerInt && gridPrice <= placeUpperInt && !CheckOrderExists(gridPrice, isBuy))
        {
            if(isBuy)
            {
                if(gridPrice < currentPrice)
                    PlaceOrder(ORDER_TYPE_BUY_LIMIT, gridPrice, true);
                else
                    PlaceOrder(ORDER_TYPE_BUY_STOP, gridPrice, true);
            }
            else
            {
                if(gridPrice > currentPrice)
                    PlaceOrder(ORDER_TYPE_SELL_LIMIT, gridPrice, false);
                else
                    PlaceOrder(ORDER_TYPE_SELL_STOP, gridPrice, false);
            }
        }
        gridPrice += step;
    }

    CleanupOrders(isBuy, placeLowerInt, placeUpperInt);
}

//+------------------------------------------------------------------+
//| Delete every pending order of one side, used when that side is   |
//| disabled. Open positions are left untouched so they can still    |
//| reach their own take profit.                                     |
//+------------------------------------------------------------------+
void DeleteSideOrders(bool isBuy)
{
    for(int i = OrdersTotal() - 1; i >= 0; i--)
    {
        ulong ticket = OrderGetTicket(i);
        if(ticket <= 0) continue;
        if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
        if(OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;

        ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
        bool isOrderBuy = (orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_BUY_STOP);
        if(isBuy != isOrderBuy) continue;

        if(trade.OrderDelete(ticket))
            Print("Deleted ", (isBuy ? "buy" : "sell"), " order (side disabled): ", EnumToString(orderType));
    }
}

//+------------------------------------------------------------------+
//| Cleanup pending orders outside the current grid bounds           |
//+------------------------------------------------------------------+
void CleanupOrders(bool isBuy, int lowerInt, int upperInt)
{
    for(int i = OrdersTotal() - 1; i >= 0; i--)
    {
        ulong ticket = OrderGetTicket(i);
        if(ticket <= 0) continue;
        if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
        if(OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;

        ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
        bool isOrderBuy = (orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_BUY_STOP);
        if(isBuy != isOrderBuy) continue;

        int orderPrice = PriceToInt(OrderGetDouble(ORDER_PRICE_OPEN));
        if(orderPrice < lowerInt || orderPrice > upperInt)
        {
            trade.OrderDelete(ticket);
            Print("Deleted out-of-range ", (isBuy ? "buy" : "sell"), " order: ", EnumToString(orderType), " Price ", DoubleToString(orderPrice * pointValue, symbolDigits));
        }
    }
}

//+------------------------------------------------------------------+
//| Generic order existence check                                    |
//+------------------------------------------------------------------+
bool CheckOrderExists(int gridPrice, bool isBuy)
{
    int tolerance = gridStepPrice / 2;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket <= 0) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

        ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        if(isBuy != (posType == POSITION_TYPE_BUY)) continue;

        if(MathAbs(PriceToInt(PositionGetDouble(POSITION_PRICE_OPEN)) - gridPrice) < tolerance)
            return true;
    }

    for(int i = OrdersTotal() - 1; i >= 0; i--)
    {
        ulong ticket = OrderGetTicket(i);
        if(ticket <= 0) continue;
        if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
        if(OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;

        ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
        bool isOrderBuy = (orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_BUY_STOP);
        if(isBuy != isOrderBuy) continue;

        if(MathAbs(PriceToInt(OrderGetDouble(ORDER_PRICE_OPEN)) - gridPrice) < tolerance)
            return true;
    }

    return false;
}

//+------------------------------------------------------------------+
//| Generic order placement function                                 |
//+------------------------------------------------------------------+
bool PlaceOrder(ENUM_ORDER_TYPE orderType, int priceInt, bool isBuy)
{
    double price = NormalizeDouble(priceInt * pointValue, symbolDigits);
    double tp = NormalizeDouble((priceInt + (isBuy ? gridStepPrice : -gridStepPrice)) * pointValue, symbolDigits);

    bool result = false;
    string typeName;

    switch(orderType)
    {
        case ORDER_TYPE_BUY_STOP:
            result = trade.BuyStop(cachedLotSize, price, _Symbol, 0, tp, ORDER_TIME_DAY, 0, "Buy Stop");
            typeName = "Buy Stop";
            break;
        case ORDER_TYPE_BUY_LIMIT:
            result = trade.BuyLimit(cachedLotSize, price, _Symbol, 0, tp, ORDER_TIME_DAY, 0, "Buy Limit");
            typeName = "Buy Limit";
            break;
        case ORDER_TYPE_SELL_STOP:
            result = trade.SellStop(cachedLotSize, price, _Symbol, 0, tp, ORDER_TIME_DAY, 0, "Sell Stop");
            typeName = "Sell Stop";
            break;
        case ORDER_TYPE_SELL_LIMIT:
            result = trade.SellLimit(cachedLotSize, price, _Symbol, 0, tp, ORDER_TIME_DAY, 0, "Sell Limit");
            typeName = "Sell Limit";
            break;
    }

    if(result)
        Print(typeName, " order success: Price:", DoubleToString(price, symbolDigits), " TP:", DoubleToString(tp, symbolDigits));
    else
        Print(typeName, " order failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());

    return result;
}

//+------------------------------------------------------------------+
