//+------------------------------------------------------------------+
//|                                            ModifyTakeProfit.mq5  |
//|                             Bulk modify take profit for positions|
//+------------------------------------------------------------------+
#property copyright "Grid Trading EA"
#property version   "1.00"

#include <Trade\Trade.mqh>

enum ENUM_POSITION_FILTER
{
    FILTER_ALL  = 0, // All
    FILTER_BUY  = 1, // Buy only
    FILTER_SELL = 2, // Sell only
};

// Input Parameters
input double               TakeProfitPrice    = 0.0;        // Take Profit price (0 = remove TP)
input ENUM_POSITION_FILTER PositionTypeFilter = FILTER_BUY; // Position type
input int                  MagicNumber        = 8002;       // Magic Number filter (0 = all positions)
input string               SymbolFilter       = "";         // Symbol filter (empty = current symbol)
input bool                 AllowLossTP        = false;      // Allow TP that would result in a loss

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    static bool done = false;
    if(done) return;
    done = true;

    string symbol = (SymbolFilter == "") ? _Symbol : SymbolFilter;
    int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

    CTrade trade;
    trade.SetDeviationInPoints(10);
    trade.SetTypeFilling(ORDER_FILLING_FOK);

    int modified = 0;
    int failed    = 0;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0) continue;

        // Symbol filter
        if(PositionGetString(POSITION_SYMBOL) != symbol) continue;

        // Magic number filter
        if(MagicNumber != 0 && PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

        // Position type filter
        ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        if(PositionTypeFilter == FILTER_BUY  && posType != POSITION_TYPE_BUY)  continue;
        if(PositionTypeFilter == FILTER_SELL && posType != POSITION_TYPE_SELL) continue;

        double sl          = PositionGetDouble(POSITION_SL);
        double openPrice   = PositionGetDouble(POSITION_PRICE_OPEN);
        double currentTp   = PositionGetDouble(POSITION_TP);

        double tp = NormalizeDouble(TakeProfitPrice, digits);

        // Skip if TP would result in a loss (unless AllowLossTP is enabled)
        if(tp != 0.0 && !AllowLossTP)
        {
            if(posType == POSITION_TYPE_BUY && tp <= openPrice)
            {
                PrintFormat("Ticket #%llu: Skipped (BUY open=%.%df, TP=%.%df would be a loss)", ticket, digits, openPrice, digits, tp);
                continue;
            }
            if(posType == POSITION_TYPE_SELL && tp >= openPrice)
            {
                PrintFormat("Ticket #%llu: Skipped (SELL open=%.%df, TP=%.%df would be a loss)", ticket, digits, openPrice, digits, tp);
                continue;
            }
        }

        // Skip if TP is already set to the target value
        if(NormalizeDouble(currentTp, digits) == tp)
        {
            PrintFormat("Ticket #%llu: Skipped (TP already %.%df)", ticket, digits, tp);
            continue;
        }

        if(trade.PositionModify(ticket, sl, tp))
        {
            modified++;
            PrintFormat("Ticket #%llu: TP set to %.%df", ticket, digits, tp);
        }
        else
        {
            failed++;
            PrintFormat("Ticket #%llu: Failed to modify TP. Error=%d", ticket, GetLastError());
        }
    }

    PrintFormat("Done. Modified=%d, Failed=%d", modified, failed);
    Alert(StringFormat("Take Profit update complete.\nModified: %d\nFailed: %d", modified, failed));
    ExpertRemove();
}
