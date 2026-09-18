//+------------------------------------------------------------------+
//|                                             PositionSummary.mq5  |
//|            Print total lots and average price grouped by         |
//|            symbol and position type (buy/sell)                   |
//+------------------------------------------------------------------+
#property copyright "Grid Trading EA"
#property version   "1.00"

// Input Parameters
input int MagicNumber = 0; // Magic Number filter (0 = all positions)

#define MAX_GROUPS 100

string groupSymbol[MAX_GROUPS];
bool   groupIsBuy[MAX_GROUPS];
double groupLots[MAX_GROUPS];
double groupValue[MAX_GROUPS]; // sum(openPrice * volume), for weighted average price
int    groupCount = 0;

long   magicNumbers[MAX_GROUPS];
int    magicCount = 0;

//+------------------------------------------------------------------+
//| Find existing group index or create a new one                    |
//+------------------------------------------------------------------+
int FindOrCreateGroup(string symbol, bool isBuy)
{
    for(int i = 0; i < groupCount; i++)
    {
        if(groupSymbol[i] == symbol && groupIsBuy[i] == isBuy)
            return i;
    }

    groupSymbol[groupCount] = symbol;
    groupIsBuy[groupCount]  = isBuy;
    groupLots[groupCount]   = 0;
    groupValue[groupCount]  = 0;
    groupCount++;
    return groupCount - 1;
}

//+------------------------------------------------------------------+
//| Add magic number to the list if not already present               |
//+------------------------------------------------------------------+
void AddMagicNumber(long magic)
{
    for(int i = 0; i < magicCount; i++)
    {
        if(magicNumbers[i] == magic)
            return;
    }
    magicNumbers[magicCount] = magic;
    magicCount++;
}

//+------------------------------------------------------------------+
//| Sort groups by Symbol, then BUY before SELL                       |
//+------------------------------------------------------------------+
void SortGroups()
{
    for(int i = 0; i < groupCount - 1; i++)
    {
        int best = i;
        for(int j = i + 1; j < groupCount; j++)
        {
            int cmp = StringCompare(groupSymbol[j], groupSymbol[best]);
            if(cmp < 0 || (cmp == 0 && groupIsBuy[j] && !groupIsBuy[best]))
                best = j;
        }
        if(best != i)
        {
            string tmpSymbol = groupSymbol[i]; groupSymbol[i] = groupSymbol[best]; groupSymbol[best] = tmpSymbol;
            bool   tmpIsBuy  = groupIsBuy[i];  groupIsBuy[i]  = groupIsBuy[best];  groupIsBuy[best]  = tmpIsBuy;
            double tmpLots   = groupLots[i];   groupLots[i]   = groupLots[best];   groupLots[best]   = tmpLots;
            double tmpValue  = groupValue[i];  groupValue[i]  = groupValue[best];  groupValue[best]  = tmpValue;
        }
    }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    groupCount = 0;
    magicCount = 0;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0) continue;

        if(MagicNumber != 0 && PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

        string symbol    = PositionGetString(POSITION_SYMBOL);
        double volume    = PositionGetDouble(POSITION_VOLUME);
        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        bool   isBuy     = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
        long   magic     = PositionGetInteger(POSITION_MAGIC);

        int g = FindOrCreateGroup(symbol, isBuy);
        groupLots[g]  += volume;
        groupValue[g] += openPrice * volume;

        AddMagicNumber(magic);
    }

    Print("=== Position Summary ===");
    if(groupCount == 0)
    {
        Print("No open positions");
    }
    else
    {
        SortGroups();
        for(int i = 0; i < groupCount; i++)
        {
            int digits = (int)SymbolInfoInteger(groupSymbol[i], SYMBOL_DIGITS);
            double avgPrice = groupValue[i] / groupLots[i];
            PrintFormat("%s %s: Lots=%.2f, AvgPrice=%s",
                        groupSymbol[i], groupIsBuy[i] ? "BUY" : "SELL",
                        groupLots[i], DoubleToString(avgPrice, digits));
        }
    }

    string magicList = "";
    for(int i = 0; i < magicCount; i++)
    {
        if(i > 0) magicList += ", ";
        magicList += IntegerToString(magicNumbers[i]);
    }
    Print("Magic Numbers: ", magicCount == 0 ? "none" : magicList);

    Print("PositionsTotal: ", PositionsTotal());

    ExpertRemove();
    return INIT_SUCCEEDED;
}
