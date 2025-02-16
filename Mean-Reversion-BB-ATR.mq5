#property copyright "Sander Silva"
#property version "0.1"
#include <Trade/Trade.mqh>

//--- Input Parameters
input double Initial_Lot = 0.01;
input double ATR_Threshold = 0.001; // 7 pips
input int BB_Period = 30;
input double BB_Deviation = 2.0;
input int ATR_Period = 24;
input double TP_Points = 61;    // 60 pips take profit
input double Recovery_TP = 144; // 100 pips for recovery trades
input int Recovery_Step = 89;   // 50 pips between recoveries

//--- Global Variables
int bbHandle, atrHandle;
double middleBand[], atrBuffer[], buyEntryPrice, sellEntryPrice;
ulong buyTickets[], sellTickets[];
datetime lastTradeTime;
CTrade trade;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Initialize indicator handles
   bbHandle = iBands(_Symbol, _Period, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
   atrHandle = iATR(_Symbol, _Period, ATR_Period);

   // Set array series
   ArraySetAsSeries(middleBand, true);
   ArraySetAsSeries(atrBuffer, true);

   return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if (!NewBar())
   {
      CheckVirtualTP(); // Check virtual TP even between candles
      return;
   }

   UpdateIndicators();

   if (CheckEntryConditions())
   {
      PlaceInitialOrders();
      lastTradeTime = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
   }

   CheckForRecoveries();
   CheckVirtualTP(); // Check virtual TP on new bar
}

//+------------------------------------------------------------------+
//| Check for new candle                                             |
//+------------------------------------------------------------------+
bool NewBar()
{
   datetime current[];
   if (CopyTime(_Symbol, _Period, 0, 1, current) != 1)
      return false;
   return current[0] != lastTradeTime;
}

//+------------------------------------------------------------------+
//| Update indicator buffers                                         |
//+------------------------------------------------------------------+
void UpdateIndicators()
{
   // Copy Bollinger Bands middle line
   CopyBuffer(bbHandle, 0, 0, 3, middleBand);

   // Copy ATR values
   CopyBuffer(atrHandle, 0, 0, 3, atrBuffer);
}

//+------------------------------------------------------------------+
//| Check entry conditions                                           |
//+------------------------------------------------------------------+
bool CheckEntryConditions()
{
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return PositionsTotal() == 0 &&
          atrBuffer[0] <= ATR_Threshold &&
          MathAbs(currentPrice - middleBand[0]) < 0.00001;
}

//+------------------------------------------------------------------+
//| Place initial straddle orders                                    |
//+------------------------------------------------------------------+
void PlaceInitialOrders()
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   buyEntryPrice = price;
   trade.Buy(Initial_Lot, _Symbol, price, 0, 0, "Initial Buy");
   ArrayResize(buyTickets, ArraySize(buyTickets) + 1);
   buyTickets[ArraySize(buyTickets) - 1] = trade.ResultOrder();

   price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   sellEntryPrice = price;
   trade.Sell(Initial_Lot, _Symbol, price, 0, 0, "Initial Sell");
   ArrayResize(sellTickets, ArraySize(sellTickets) + 1);
   sellTickets[ArraySize(sellTickets) - 1] = trade.ResultOrder();
}

//+------------------------------------------------------------------+
//| Check for needed recoveries                                      |
//+------------------------------------------------------------------+
void CheckForRecoveries()
{
   CheckBuyRecoveries();
   CheckSellRecoveries();
}

//+------------------------------------------------------------------+
//| Check buy side recoveries                                        |
//+------------------------------------------------------------------+
void CheckBuyRecoveries()
{
   if (ArraySize(buyTickets) == 0)
      return;

   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double priceDiff = (buyEntryPrice - currentPrice) / _Point;
   int requiredLevels = (int)(priceDiff / Recovery_Step);

   if (requiredLevels > ArraySize(buyTickets) - 1)
   {
      OpenRecoveryTrade(ORDER_TYPE_BUY, currentPrice, requiredLevels);
   }
}

//+------------------------------------------------------------------+
//| Check sell side recoveries                                       |
//+------------------------------------------------------------------+
void CheckSellRecoveries()
{
   if (ArraySize(sellTickets) == 0)
      return;

   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double priceDiff = (currentPrice - sellEntryPrice) / _Point;
   int requiredLevels = (int)(priceDiff / Recovery_Step);

   if (requiredLevels > ArraySize(sellTickets) - 1)
   {
      OpenRecoveryTrade(ORDER_TYPE_SELL, currentPrice, requiredLevels);
   }
}

//+------------------------------------------------------------------+
//| Open recovery trade                                              |
//+------------------------------------------------------------------+
void OpenRecoveryTrade(ENUM_ORDER_TYPE type, double price, int level)
{
   double lotSize = Initial_Lot * MathPow(2, level);

   if (type == ORDER_TYPE_BUY)
   {
      trade.Buy(lotSize, _Symbol, price, 0, 0, "Recovery Buy Lvl" + string(level));
      ArrayResize(buyTickets, ArraySize(buyTickets) + 1);
      buyTickets[ArraySize(buyTickets) - 1] = trade.ResultOrder();
   }
   else
   {
      trade.Sell(lotSize, _Symbol, price, 0, 0, "Recovery Sell Lvl" + string(level));
      ArrayResize(sellTickets, ArraySize(sellTickets) + 1);
      sellTickets[ArraySize(sellTickets) - 1] = trade.ResultOrder();
   }
}

//+------------------------------------------------------------------+
//| Check virtual take profit levels                                 |
//+------------------------------------------------------------------+
void CheckVirtualTP()
{
   // Check for buy positions
   if (PositionsTotalByType(POSITION_TYPE_BUY) > 0)
   {
      double breakeven = CalculateBreakeven(POSITION_TYPE_BUY);
      double tpPrice = breakeven + TP_Points * _Point;
      double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      if (currentBid >= tpPrice && breakeven > 0)
      {
         CloseAllPositions(POSITION_TYPE_BUY);
         ArrayFree(buyTickets);
      }
   }

   // Check for sell positions
   if (PositionsTotalByType(POSITION_TYPE_SELL) > 0)
   {
      double breakeven = CalculateBreakeven(POSITION_TYPE_SELL);
      double tpPrice = breakeven - TP_Points * _Point;
      double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if (currentAsk <= tpPrice && breakeven > 0)
      {
         CloseAllPositions(POSITION_TYPE_SELL);
         ArrayFree(sellTickets);
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate breakeven price for position type                      |
//+------------------------------------------------------------------+
double CalculateBreakeven(ENUM_POSITION_TYPE type)
{
   double totalVolume = 0;
   double weightedPrice = 0;

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_TYPE) == type)
      {
         double volume = PositionGetDouble(POSITION_VOLUME);
         double entry = PositionGetDouble(POSITION_PRICE_OPEN);
         totalVolume += volume;
         weightedPrice += entry * volume;
      }
   }

   if (totalVolume > 0)
      return weightedPrice / totalVolume;

   return 0.0;
}

//+------------------------------------------------------------------+
//| Get number of positions by type                                  |
//+------------------------------------------------------------------+
int PositionsTotalByType(ENUM_POSITION_TYPE type)
{
   int count = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_TYPE) == type)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Close all positions of specified type                            |
//+------------------------------------------------------------------+
void CloseAllPositions(ENUM_POSITION_TYPE type)
{
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_TYPE) == type)
      {
         trade.PositionClose(ticket);
      }
   }
}
//+------------------------------------------------------------------+