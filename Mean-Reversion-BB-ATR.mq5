#include <Trade/Trade.mqh>

//--- Input Parameters
input double Initial_Lot = 0.01;
input int BB_Period = 200;
input double BB_Deviation = 2.0;
input int ATR_Period = 50;
input double TP_Points = 100;                    // Take profit in points
input int Recovery_Step = 100;                   // Step between recoveries in points
input double Recovery_Distance_Multiplier = 1.5; // Distance multiplier for recovery distance
input int RSI_Period = 14;
input int RSI_Overbought = 70;
input int RSI_Oversold = 30;
input double ATR_Decrease_Percent = 15.0; // Required ATR decrease percentage

//--- Trading Hours
input int StartHour = 0; // Trading start hour (server time)
input int StopHour = 24; // Trading end hour (server time)

//--- Global Variables
int bbHandle, atrHandle, rsiHandle;
double upperBand[], middleBand[], lowerBand[], atrBuffer[], rsiBuffer[];
double buyEntryPrice, sellEntryPrice;

//--- Trade Tracking
double lastBuyTradePrice, lastSellTradePrice;
int RecoveryLevel = 0;
ulong buyTickets[], sellTickets[];
datetime lastTradeTime;
CTrade trade;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   bbHandle = iBands(_Symbol, _Period, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
   atrHandle = iATR(_Symbol, _Period, ATR_Period);
   rsiHandle = iRSI(_Symbol, _Period, RSI_Period, PRICE_CLOSE);

   ArraySetAsSeries(upperBand, true);
   ArraySetAsSeries(middleBand, true);
   ArraySetAsSeries(lowerBand, true);
   ArraySetAsSeries(atrBuffer, true);
   ArraySetAsSeries(rsiBuffer, true);

   return (INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if (!NewBar())
   {
      CheckVirtualTP();
      return;
   }

   UpdateIndicators();

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int currentHour = dt.hour;

   // Check initial trade conditions
   if (PositionsTotal() == 0)
   {
      if ((currentHour >= StartHour && currentHour < StopHour) && CheckEntryConditions())
      {
         PlaceInitialOrders();
         lastTradeTime = iTime(_Symbol, _Period, 0);
      }
   }

   // Check recovery conditions
   CheckForRecoveries();
   CheckVirtualTP();
}

//+------------------------------------------------------------------+
//| Check for new candle                                             |
//+------------------------------------------------------------------+
bool NewBar()
{
   datetime currentBar = iTime(_Symbol, _Period, 0);
   return currentBar != lastTradeTime;
}

//+------------------------------------------------------------------+
//| Update indicator buffers                                         |
//+------------------------------------------------------------------+
void UpdateIndicators()
{
   CopyBuffer(bbHandle, 0, 0, 3, middleBand);
   CopyBuffer(bbHandle, 1, 0, 3, upperBand);
   CopyBuffer(bbHandle, 2, 0, 3, lowerBand);
   CopyBuffer(atrHandle, 0, 0, 3, atrBuffer);
   CopyBuffer(rsiHandle, 0, 0, 3, rsiBuffer);
}

//+------------------------------------------------------------------+
//| Check initial entry conditions                                   |
//+------------------------------------------------------------------+
bool CheckEntryConditions()
{
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // ATR decrease condition
   bool atrCondition = (atrBuffer[1] != 0) &&
                       ((atrBuffer[1] - atrBuffer[0]) / atrBuffer[1] >= (ATR_Decrease_Percent / 100.0));

   return atrCondition;
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

   lastBuyTradePrice = buyEntryPrice;
   lastSellTradePrice = sellEntryPrice;
   lastTradeTime = iTime(_Symbol, _Period, 0);
}

//+------------------------------------------------------------------+
//| Check for recovery opportunities                                 |
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
   if (PositionsTotalByType(POSITION_TYPE_BUY) == 0)
      return;

   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if ((lastBuyTradePrice - currentBid) / _Point >= Recovery_Step * RecoveryLevel * Recovery_Distance_Multiplier)
   {
      if (rsiBuffer[0] < RSI_Oversold && currentBid < lowerBand[0])
      {
         OpenRecoveryTrade(ORDER_TYPE_BUY, SymbolInfoDouble(_Symbol, SYMBOL_ASK), RecoveryLevel + 1);
         RecoveryLevel++;
         lastTradeTime = iTime(_Symbol, _Period, 0); // Update last trade time
      }
   }
}

//+------------------------------------------------------------------+
//| Check sell side recoveries                                       |
//+------------------------------------------------------------------+
void CheckSellRecoveries()
{
   if (PositionsTotalByType(POSITION_TYPE_SELL) == 0)
      return;

   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if ((currentAsk - lastSellTradePrice) / _Point >= Recovery_Step * RecoveryLevel * Recovery_Distance_Multiplier)
   {
      if (rsiBuffer[0] > RSI_Overbought && currentAsk > upperBand[0])
      {
         OpenRecoveryTrade(ORDER_TYPE_SELL, SymbolInfoDouble(_Symbol, SYMBOL_BID), RecoveryLevel + 1);
         RecoveryLevel++;
         lastTradeTime = iTime(_Symbol, _Period, 0); // Update last trade time
      }
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
      lastBuyTradePrice = price;
   }
   else
   {
      trade.Sell(lotSize, _Symbol, price, 0, 0, "Recovery Sell Lvl" + string(level));
      ArrayResize(sellTickets, ArraySize(sellTickets) + 1);
      sellTickets[ArraySize(sellTickets) - 1] = trade.ResultOrder();
      lastSellTradePrice = price;
   }
}

//+------------------------------------------------------------------+
//| Check virtual take profit levels                                 |
//+------------------------------------------------------------------+
void CheckVirtualTP()
{
   // Buy positions TP check
   if (PositionsTotalByType(POSITION_TYPE_BUY) > 0)
   {
      double breakeven = CalculateBreakeven(POSITION_TYPE_BUY);
      double tpPrice = breakeven + TP_Points * _Point;
      if (SymbolInfoDouble(_Symbol, SYMBOL_BID) >= tpPrice && breakeven > 0)
      {
         CloseAllPositions(POSITION_TYPE_BUY);
         ArrayFree(buyTickets);
      }
   }

   // Sell positions TP check
   if (PositionsTotalByType(POSITION_TYPE_SELL) > 0)
   {
      double breakeven = CalculateBreakeven(POSITION_TYPE_SELL);
      double tpPrice = breakeven - TP_Points * _Point;
      if (SymbolInfoDouble(_Symbol, SYMBOL_ASK) <= tpPrice && breakeven > 0)
      {
         CloseAllPositions(POSITION_TYPE_SELL);
         ArrayFree(sellTickets);
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate breakeven price                                        |
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
   return (totalVolume > 0) ? weightedPrice / totalVolume : 0.0;
}

//+------------------------------------------------------------------+
//| Get positions count by type                                      |
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
         RecoveryLevel = 0;
      }
   }
}