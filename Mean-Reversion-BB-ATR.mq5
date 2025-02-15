#property copyright "Sander Silva"
#property version "0.1"
#include <Trade/Trade.mqh>

//--- Input Parameters
input double Initial_Lot = 0.01;
input double ATR_Threshold = 0.00070; // 7 pips
input int BB_Period = 20;
input double BB_Deviation = 2.0;
input int ATR_Period = 14;
input double TP_Points = 60;    // 100 pips take profit
input double Recovery_TP = 100; // 50 pips for recovery trades
input int Recovery_Step = 50;   // 100 pips between recoveries

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
      return;

   UpdateIndicators();

   if (CheckEntryConditions())
   {
      PlaceInitialOrders();
      lastTradeTime = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
   }

   CheckForRecoveries();
   MonitorRecoveryClosures();
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
   trade.Buy(Initial_Lot, _Symbol, price, 0, price + TP_Points * _Point, "Initial Buy");
   ArrayResize(buyTickets, ArraySize(buyTickets) + 1);
   buyTickets[ArraySize(buyTickets) - 1] = trade.ResultOrder();

   price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   sellEntryPrice = price;
   trade.Sell(Initial_Lot, _Symbol, price, 0, price - TP_Points * _Point, "Initial Sell");
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
   UpdateTpForDirection(type == ORDER_TYPE_BUY ? POSITION_TYPE_BUY : POSITION_TYPE_SELL);
}

//+------------------------------------------------------------------+
//| Update take profit levels                                        |
//+------------------------------------------------------------------+
void UpdateTpForDirection(ENUM_POSITION_TYPE type)
{
   double totalLots = 0;
   double weightedPrice = 0;

   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_TYPE) == type)
      {
         double lots = PositionGetDouble(POSITION_VOLUME);
         double entry = PositionGetDouble(POSITION_PRICE_OPEN);
         totalLots += lots;
         weightedPrice += entry * lots;
      }
   }

   if (totalLots > 0)
   {
      double breakeven = weightedPrice / totalLots;
      double tpPrice = type == POSITION_TYPE_BUY ? breakeven + Recovery_TP * _Point : breakeven - Recovery_TP * _Point;

      for (int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if (PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_TYPE) == type)
         {
            trade.PositionModify(ticket, PositionGetDouble(POSITION_SL), tpPrice);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Monitor recovery closures                                        |
//+------------------------------------------------------------------+
void MonitorRecoveryClosures()
{
   CheckRecoveryClosure(buyTickets, POSITION_TYPE_BUY);
   CheckRecoveryClosure(sellTickets, POSITION_TYPE_SELL);
}

//+------------------------------------------------------------------+
//| Check recovery closure                                           |
//+------------------------------------------------------------------+
void CheckRecoveryClosure(ulong &tickets[], ENUM_POSITION_TYPE type)
{
   for (int i = ArraySize(tickets) - 1; i >= 0; i--)
   {
      if (!PositionSelectByTicket(tickets[i]))
      {
         CloseAllPositions(type);
         ArrayFree(tickets);
         break;
      }
   }
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