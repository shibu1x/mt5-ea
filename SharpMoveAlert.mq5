//+------------------------------------------------------------------+
//|                                          SharpMoveAlert.mq5      |
//|   Alert when price moves sharply within a short window (M1)      |
//+------------------------------------------------------------------+
#property copyright "Grid Trading EA"
#property version   "1.00"

input group "=== Sharp Move Alert Settings ==="
input int      WindowMinutes = 5;      // Window to Measure Sudden Move (minutes)
input double   MovePips = 70;          // Move Threshold to Trigger Alert (pips)
input double   AlertCooldownHours = 1; // Minimum Time Between Alerts (hours)

int      symbolDigits;
int      pipFactor;
double   pointValue;
int      movePriceThreshold;
datetime nextAlertAllowed;

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
    pointValue   = _Point;
    symbolDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    pipFactor    = (symbolDigits == 3 || symbolDigits == 5) ? 10 : 100;
    movePriceThreshold = (int)MathRound(MovePips * pipFactor);

    if(WindowMinutes <= 0)
    {
        Print("Error: Window minutes must be positive");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(MovePips <= 0)
    {
        Print("Error: Move pips must be positive");
        return INIT_PARAMETERS_INCORRECT;
    }

    if(AlertCooldownHours <= 0)
    {
        Print("Error: Alert cooldown hours must be positive");
        return INIT_PARAMETERS_INCORRECT;
    }

    Print("=== Sharp Move Alert EA Initialization ===");
    Print("Window: ", WindowMinutes, " min  Threshold: ", MovePips, " pips  Cooldown: ", AlertCooldownHours, "h");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    CheckSharpMove();
}

//+------------------------------------------------------------------+
//| Detect a sharp move: price has moved at least MovePips within     |
//| the last WindowMinutes, measured on M1 bars regardless of the     |
//| chart timeframe this EA is attached to. Sends a notification on   |
//| detection, then suppresses further alerts until AlertCooldownHours|
//| has passed.                                                       |
//+------------------------------------------------------------------+
void CheckSharpMove()
{
    if(TimeCurrent() < nextAlertAllowed) return;

    int shift = iBarShift(_Symbol, PERIOD_M1, TimeCurrent() - WindowMinutes * 60, false);
    if(shift < 0) return;

    double priceThen = iClose(_Symbol, PERIOD_M1, shift);
    double priceNow  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    int moveInt = (int)MathAbs(PriceToInt(priceNow) - PriceToInt(priceThen));

    if(moveInt < movePriceThreshold) return;

    nextAlertAllowed = TimeCurrent() + (datetime)(AlertCooldownHours * 3600);

    SendNotification(StringFormat("%s: Sudden move %.1f pips within %d min (threshold %.1f)",
                                   _Symbol, moveInt / (double)pipFactor, WindowMinutes, MovePips));
    Print("Sharp move detected: ", DoubleToString(moveInt / (double)pipFactor, 1),
          " pips within ", WindowMinutes, " min. Next alert allowed after ",
          TimeToString(nextAlertAllowed, TIME_DATE | TIME_MINUTES));
}
