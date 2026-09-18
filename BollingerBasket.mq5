//+------------------------------------------------------------------+
//|                                              BollingerBasket.mq5 |
//|                    Bollinger Bands Basket EA                      |
//+------------------------------------------------------------------+
#property copyright "Grid Trading EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

enum ENUM_BANDS_MODE
{
    BANDS_MODE_BREAKOUT  = 0,  // Breakout (trend-follow): buy on close above upper band, sell on close below lower band
    BANDS_MODE_REVERSION = 1   // Reversion (fade): buy on close below lower band, sell on close above upper band
};

//+------------------------------------------------------------------+
//| Human-readable description of the active entry mode              |
//+------------------------------------------------------------------+
string BandsModeDescription()
{
    switch(BandsMode)
    {
        case BANDS_MODE_BREAKOUT:  return "breakout (long: close>upper band, short: close<lower band)";
        case BANDS_MODE_REVERSION: return "reversion (long: close<lower band, short: close>upper band)";
    }
    return "unknown";
}

// Input Parameters
input group "=== Bollinger Entry Filter ==="
input ENUM_BANDS_MODE BandsMode = BANDS_MODE_REVERSION; // Entry Mode (price beyond band: breakout = follow, reversion = fade)
input int      BandsPeriod = 20;            // Bollinger Bands Period (entry filter)
input double   BandsDeviation = 2.0;        // Bollinger Bands Deviation (std devs)
input double   BandsDistanceMinPips = 0;    // Min close-beyond-band distance to allow entry (pips, 0 = ignore)

input group "=== Basic Settings ==="
input double   LotSize = 0.01;              // Initial Lot Size
input double   LotMultiplier = 1.5;         // Lot Multiplier per Grid Level (1.0 = fixed lot)
input int      GridStepPips = 10;           // Grid Step (pips)
input double   GridStepMultiplier = 1.2;    // Grid Step Multiplier per Grid Level (1.0 = fixed step)
input int      MaxGridLevels = 10;          // Max Grid Levels (common, 0 = unlimited; used unless a per-direction value is set)
input int      BasketTakeProfitPips = 10;   // Basket Take Profit (pips, volume-weighted avg, 0 = disabled)
input int      BasketStopLossPips = 0;      // Basket Stop Loss (pips, volume-weighted avg, 0 = disabled)
input double   MaxSpreadPips = 1.1;         // Max Spread to Allow New Entries (pips, 0 = no limit)
input int      MagicNumber = 8009;          // Magic Number

input group "=== Alerts ==="
input bool     EnableEntryEmail = false;    // Email a notification when a new basket's first position (level 0) opens

input group "=== Trading Hours ==="
input int      TradingStartHour = 0;        // Trading Start Hour (server time, 0-23)
input int      TradingEndHour = 0;          // Trading End Hour (server time, 0-23; start == end means no restriction)

input group "=== Nanpin Stop Distance ==="
input int      ReferenceHour = 1;                 // Reference Hour (server time, 0-23): the close of this hour's bar becomes the daily reference price
input int      ReferenceMaxDistancePips = 0;      // Max Distance from Reference Price to Allow Nanpin (pips, 0 = no limit)

input group "=== Buy Basket Settings ==="
input bool     BuyOpenNew = true;           // Open New Buy Baskets (false = close-only for an open basket)
input int      BuyMaxGridLevels = 0;        // Buy Max Grid Levels (0 = use common MaxGridLevels; >=1 overrides it)
input double   BuyUpperLimitPrice = 0;      // Buy Upper Limit Price (0 = no limit)

input group "=== Sell Basket Settings ==="
input bool     SellOpenNew = true;          // Open New Sell Baskets (false = close-only for an open basket)
input int      SellMaxGridLevels = 0;       // Sell Max Grid Levels (0 = use common MaxGridLevels; >=1 overrides it)
input double   SellLowerLimitPrice = 0;     // Sell Lower Limit Price (0 = no limit)

// Global Variables
CTrade trade;
int bandsHandle;
int gridStepPrice;
double pointValue;
double cachedLotSize;
int symbolDigits;
int buyUpperLimitInt;
int sellLowerLimitInt;
int maxSpreadPrice;
int bandsDistanceMinPrice;
int referenceMaxDistancePrice;
int pipFactor;
bool tradingHoursRestricted;
int tradingStartMinutes;
int tradingEndMinutes;
datetime buyLastEntryBar  = 0;
datetime sellLastEntryBar = 0;

// Nanpin stop-distance reference price: the close of the ReferenceHour bar,
// captured once per calendar day (server time) and held fixed until the
// next day's bar. Independent of the Bollinger entry trigger — it only
// gates grid-level additions (see IsWithinReferenceDistance()).
int  referenceDay   = 0;
int  referenceMonth = 0;
int  referenceYear  = 0;
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
    buyUpperLimitInt  = BuyUpperLimitPrice  > 0 ? PriceToInt(BuyUpperLimitPrice)  : 0;
    sellLowerLimitInt = SellLowerLimitPrice > 0 ? PriceToInt(SellLowerLimitPrice) : 0;
    maxSpreadPrice    = PipsToInt(MaxSpreadPips);
    bandsDistanceMinPrice = PipsToInt(BandsDistanceMinPips);
    referenceMaxDistancePrice = PipsToInt(ReferenceMaxDistancePips);

    tradingStartMinutes  = TradingStartHour * 60;
    tradingEndMinutes    = TradingEndHour * 60;
    tradingHoursRestricted = (tradingStartMinutes != tradingEndMinutes);

    bandsHandle = iBands(_Symbol, PERIOD_CURRENT, BandsPeriod, 0, BandsDeviation, PRICE_CLOSE);
    if(bandsHandle == INVALID_HANDLE)
    {
        Print("Error: Failed to create indicator handle");
        return INIT_FAILED;
    }

    Print("=== BollingerBasket EA Initialization ===");
    Print("Bollinger Entry Filter: ",
          StringFormat("period %d / dev %.1f  %s%s",
                       BandsPeriod, BandsDeviation,
                       BandsModeDescription(),
                       (bandsDistanceMinPrice > 0 ? ", min distance " + DoubleToString(BandsDistanceMinPips, 1) + " pips" : "")));
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
    Print("Nanpin Stop Distance: ", (referenceMaxDistancePrice > 0 ?
          DoubleToString(ReferenceMaxDistancePips, 1) + " pips from the " + IntegerToString(ReferenceHour) + ":00 daily reference price" :
          "no limit"));
    Print("Basket TP: ", (BasketTakeProfitPips > 0 ? IntegerToString(BasketTakeProfitPips) + " pips" : "disabled"),
          "  Basket SL: ", (BasketStopLossPips > 0 ? IntegerToString(BasketStopLossPips) + " pips" : "disabled"));
    Print("Entry Email Alert: ", (EnableEntryEmail ? "enabled" : "disabled"));
    Print("Buy Basket: ", (BuyOpenNew ? "open new" : "close-only"),
          " Upper Limit: ", (buyUpperLimitInt > 0 ? DoubleToString(BuyUpperLimitPrice, symbolDigits) : "none"));
    Print("Sell Basket: ", (SellOpenNew ? "open new" : "close-only"),
          " Lower Limit: ", (sellLowerLimitInt > 0 ? DoubleToString(SellLowerLimitPrice, symbolDigits) : "none"));

    // Both sides may be close-only at once: a pure wind-down of open baskets
    // with no new entries is a valid configuration, so it is not rejected here.

    if(BandsPeriod <= 0)
    {
        Print("Error: Bollinger Bands period must be positive");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(BandsDeviation <= 0)
    {
        Print("Error: Bollinger Bands deviation must be positive");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(BandsDistanceMinPips < 0)
    {
        Print("Error: Bollinger distance minimum must be non-negative");
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

    Print("Initialization Complete");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(bandsHandle != INVALID_HANDLE) IndicatorRelease(bandsHandle);
    Print("BollingerBasket EA Terminated");
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
//| Capture the ReferenceHour close once per calendar day (server    |
//| time), for the nanpin stop-distance filter only. On a new day    |
//| the reference is cleared; once TimeCurrent() reaches              |
//| ReferenceHour:00, the close of the H1 bar ending at that instant |
//| is captured and held fixed for the rest of the day. Independent  |
//| of the Bollinger entry trigger and the level-0 per-bar gate.     |
//+------------------------------------------------------------------+
void UpdateReference()
{
    MqlDateTime now;
    TimeToStruct(TimeCurrent(), now);

    if(now.day != referenceDay || now.mon != referenceMonth || now.year != referenceYear)
    {
        referenceReady = false;
        referenceDay   = now.day;
        referenceMonth = now.mon;
        referenceYear  = now.year;
    }

    if(referenceReady) return;

    MqlDateTime target;
    TimeToStruct(TimeCurrent(), target);
    target.hour = ReferenceHour;
    target.min  = 0;
    target.sec  = 0;
    datetime targetTime = StructToTime(target);

    if(TimeCurrent() < targetTime) return;

    int shift = iBarShift(_Symbol, PERIOD_H1, targetTime - 1, false);
    if(shift < 0) return;

    referencePriceInt = PriceToInt(iClose(_Symbol, PERIOD_H1, shift));
    referenceReady = true;

    Print("Reference price captured for ", TimeToString(TimeCurrent(), TIME_DATE), " at ", ReferenceHour,
          ":00 -> ", DoubleToString(referencePriceInt * pointValue, symbolDigits));
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
        // Gate the level-0 entry to at most one per bar per side so a
        // TP-then-reopen loop can't fire every tick.
        datetime lastEntryBar = isBuy ? buyLastEntryBar : sellLastEntryBar;
        datetime currentBar   = iTime(_Symbol, PERIOD_CURRENT, 0);

        if(openNew && currentBar != lastEntryBar &&
           IsWithinTradingHours() && IsWithinLimit(isBuy, currentPrice) &&
           IsSpreadAllowed() && IsBandsEntryAllowed(isBuy))
        {
            if(OpenGridOrder(isBuy, 0))
            {
                if(isBuy) buyLastEntryBar  = currentBar;
                else      sellLastEntryBar = currentBar;
            }
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

    int maxLevels = GetMaxGridLevels(isBuy);
    if(maxLevels > 0 && count >= maxLevels) return;

    int stepPrice = CalculateGridStepPrice(count);
    bool triggered = isBuy ? (currentPrice <= extremePriceInt - stepPrice)
                            : (currentPrice >= extremePriceInt + stepPrice);

    if(triggered && IsWithinTradingHours() && IsSpreadAllowed() && IsWithinReferenceDistance(currentPrice))
    {
        OpenGridOrder(isBuy, count);
    }
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
//| Check whether price sits beyond the Bollinger band that a new    |
//| basket would follow. In BANDS_MODE_BREAKOUT (trend-follow) a buy |
//| needs the close above the upper band and a sell needs it below   |
//| the lower band; in BANDS_MODE_REVERSION (fade) the sides are     |
//| mirrored — a buy needs the close below the lower band, a sell    |
//| above the upper band. distanceInt is how far the close sits      |
//| beyond the relevant band; BandsDistanceMinPips optionally        |
//| requires it to be at least that many pips. Only applies to the   |
//| position that starts a new basket, not grid-level additions.     |
//+------------------------------------------------------------------+
bool IsBandsEntryAllowed(bool isBuy)
{
    double upper[], lower[];
    ArraySetAsSeries(upper, true);
    ArraySetAsSeries(lower, true);
    if(CopyBuffer(bandsHandle, 1, 1, 1, upper) < 1) return false;
    if(CopyBuffer(bandsHandle, 2, 1, 1, lower) < 1) return false;

    double closePrice = iClose(_Symbol, PERIOD_CURRENT, 1);
    if(closePrice <= 0) return false;

    int closeInt = PriceToInt(closePrice);
    int upperInt = PriceToInt(upper[0]);
    int lowerInt = PriceToInt(lower[0]);

    int distanceInt;
    if(BandsMode == BANDS_MODE_BREAKOUT)
        distanceInt = isBuy ? (closeInt - upperInt) : (lowerInt - closeInt);
    else
        distanceInt = isBuy ? (lowerInt - closeInt) : (closeInt - upperInt);

    if(bandsDistanceMinPrice > 0 && distanceInt < bandsDistanceMinPrice) return false;

    return distanceInt > 0;
}

//+------------------------------------------------------------------+
//| Nanpin stop-distance filter: once price has moved more than      |
//| ReferenceMaxDistancePips away from today's ReferenceHour close   |
//| (either direction), grid-level additions are suspended - the     |
//| basket is still monitored for TP/SL and the level-0 entry (which |
//| is gated by the Bollinger bands, not this reference) is          |
//| unaffected. 0 = no limit.                                         |
//+------------------------------------------------------------------+
bool IsWithinReferenceDistance(int currentPriceInt)
{
    if(referenceMaxDistancePrice <= 0) return true;
    if(!referenceReady) return true;
    return MathAbs(currentPriceInt - referencePriceInt) <= referenceMaxDistancePrice;
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
    {
        Print((isBuy ? "Buy" : "Sell"), " grid order opened: Level ", level, " Lot ", DoubleToString(lot, 2));
        if(level == 0) SendEntryEmail(isBuy, lot);
    }
    else
        Print((isBuy ? "Buy" : "Sell"), " grid order failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());

    return result;
}

//+------------------------------------------------------------------+
//| Email a notification that a new basket's first position (level   |
//| 0) has just opened. Delivery uses the terminal's configured      |
//| email account (Tools > Options > Email); SendMail is a no-op in  |
//| the Strategy Tester. Only the level-0 entry triggers this — grid |
//| adds and basket closes do not.                                   |
//+------------------------------------------------------------------+
void SendEntryEmail(bool isBuy, double lot)
{
    if(!EnableEntryEmail) return;

    double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                          : SymbolInfoDouble(_Symbol, SYMBOL_BID);

    string subject = StringFormat("[BollingerBasket] %s new %s basket",
                                  _Symbol, (isBuy ? "BUY" : "SELL"));
    string body = StringFormat(
        "BollingerBasket opened a new basket (level 0).\r\n"
        "Symbol:    %s\r\n"
        "Direction: %s\r\n"
        "Lot:       %s\r\n"
        "Price:     %s\r\n"
        "Time:      %s (server)\r\n"
        "Magic:     %d",
        _Symbol,
        (isBuy ? "BUY" : "SELL"),
        DoubleToString(lot, 2),
        DoubleToString(price, symbolDigits),
        TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
        MagicNumber);

    if(!SendMail(subject, body))
        Print("Entry email failed: error ", GetLastError(),
              " (check MetaTrader Tools > Options > Email)");
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
