#include <Trade/Trade.mqh>

input double initialLot = 0.01;
input int bbPeriod = 142;
input double bbDeviation = 2;
input int atrPeriod = 86;

input double profitMinMoney = 25;

input int lossRecoveryTrailingStart = 100;
input double lossAtrDistanceMultiplier = 2.6;
input double lossRecoveryDistanceMultiplier = 2.5;

input int maxAllowedSpread = 7;

int bandHandle, atrIndicatorHandle;
double atrData[], upperBB[], middleBB[], lowerBB[];
double buyEntry = 0.0, sellEntry = 0.0;

double currentSpread;
double lastBuyPrice = 0.0, lastSellPrice = 0.0;
int buyRecoveryLevel = 0, sellRecoveryLevel = 0;
datetime lastBarTime = 0;
CTrade trade;

int buyPositionsCount = 0;
int sellPositionsCount = 0;

int OnInit()
{
   atrIndicatorHandle = iATR(_Symbol, _Period, atrPeriod);
   bandHandle = iBands(_Symbol, _Period, bbPeriod, 0, bbDeviation, PRICE_CLOSE);

   ArraySetAsSeries(atrData, true);
   ArraySetAsSeries(upperBB, true);
   ArraySetAsSeries(middleBB, true);
   ArraySetAsSeries(lowerBB, true);

   ArrayResize(middleBB, 2);
   ArrayResize(upperBB, 2);
   ArrayResize(lowerBB, 2);
   ArrayResize(atrData, 2);

   return INIT_SUCCEEDED;
}

void OnTick()
{
   bool newBar = isNewBar();
   if (!newBar)
      return;

   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   currentSpread = (currentAsk - currentBid) / _Point;

   // Exit if spread is too high
   if (currentSpread > maxAllowedSpread)
   {
      return;
   }

   updateIndicators();
   manageVirtualStops(currentBid, currentAsk);

   if (PositionsTotal() == 0)
   {
      buyRecoveryLevel = 0;
      sellRecoveryLevel = 0;
   }

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if (checkEntryConditions(currentBid) && dt.day_of_week != 5)
   {
      if (buyPositionsCount == 0)
      {
         buyEntry = currentAsk;
         trade.Buy(initialLot, _Symbol, currentAsk, 0, 0, "Initial Buy");
         lastBuyPrice = buyEntry;
      }

      if (sellPositionsCount == 0)
      {
         sellEntry = currentBid;
         trade.Sell(initialLot, _Symbol, currentBid, 0, 0, "Initial Sell");
         lastSellPrice = sellEntry;
      }

      lastBarTime = iTime(_Symbol, _Period, 0);
   }

   checkForRecoveries(currentBid, currentAsk);
}

void manageVirtualStops(double currentBid, double currentAsk)
{
   if (buyPositionsCount > 0)
   {
      double buyProfit = calculateTotalProfit(POSITION_TYPE_BUY, buyPositionsCount);
      if (buyProfit >= profitMinMoney)
      {
         closeAllPositions(POSITION_TYPE_BUY);
      }
   }

   if (sellPositionsCount > 0)
   {
      double sellProfit = calculateTotalProfit(POSITION_TYPE_SELL, sellPositionsCount);
      if (sellProfit >= profitMinMoney)
      {
         closeAllPositions(POSITION_TYPE_SELL);
      }
   }
}

bool isNewBar()
{
   datetime currentBar = iTime(_Symbol, _Period, 0);
   return (currentBar != lastBarTime);
}

void updateIndicators()
{
   CopyBuffer(bandHandle, 0, 0, 2, middleBB);
   CopyBuffer(bandHandle, 1, 0, 2, upperBB);
   CopyBuffer(bandHandle, 2, 0, 2, lowerBB);
   CopyBuffer(atrIndicatorHandle, 0, 0, 2, atrData);
}

bool checkEntryConditions(double price)
{
   bool priceNearMiddle = MathAbs(price - middleBB[0]) <= 2 * _Point;
   bool momentum = MathAbs(middleBB[0] - middleBB[1]) < _Point * 2;
   return priceNearMiddle && momentum;
}

void checkForRecoveries(double currentBid, double currentAsk)
{
   double currentAtr = atrData[0];

   if (currentBid <= lowerBB[0] && lastBuyPrice > 0)
   {
      double requiredDistance = currentAtr * lossAtrDistanceMultiplier * (buyRecoveryLevel + 1);
      if ((lastBuyPrice - currentBid) >= requiredDistance)
      {
         openTrade(ORDER_TYPE_BUY, currentAsk, currentAtr);
         buyRecoveryLevel++;
      }
   }

   if (currentBid >= upperBB[0] && lastSellPrice > 0)
   {
      double requiredDistance = currentAtr * lossAtrDistanceMultiplier * (sellRecoveryLevel + 1);
      if ((currentBid - lastSellPrice) >= requiredDistance)
      {
         openTrade(ORDER_TYPE_SELL, currentBid, currentAtr);
         sellRecoveryLevel++;
      }
   }
}

void openTrade(ENUM_ORDER_TYPE type, double price, double atrValue)
{
   double lotSize;
   if (type == ORDER_TYPE_BUY)
   {
      lotSize = initialLot * (1 << buyRecoveryLevel);
      trade.Buy(lotSize, _Symbol, price, 0, 0, "Recovery Buy Lvl" + IntegerToString(buyRecoveryLevel + 1));
      lastBuyPrice = price;
   }
   else
   {
      lotSize = initialLot * (1 << sellRecoveryLevel);
      trade.Sell(lotSize, _Symbol, price, 0, 0, "Recovery Sell Lvl" + IntegerToString(sellRecoveryLevel + 1));
      lastSellPrice = price;
   }
}

double calculateTotalProfit(ENUM_POSITION_TYPE type, int expectedCount)
{
   if (expectedCount <= 0)
      return 0.0;
   double totalProfit = 0.0;
   int count = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_TYPE) == type)
      {
         totalProfit += PositionGetDouble(POSITION_PROFIT);
         totalProfit += PositionGetDouble(POSITION_SWAP);
         totalProfit += PositionGetDouble(POSITION_COMMISSION);
         count++;
         if (count == expectedCount)
            break;
      }
   }
   return totalProfit;
}

void closeAllPositions(ENUM_POSITION_TYPE type)
{
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_TYPE) == type)
         trade.PositionClose(ticket);
   }

   if (type == POSITION_TYPE_BUY)
      buyRecoveryLevel = 0;
   else if (type == POSITION_TYPE_SELL)
      sellRecoveryLevel = 0;
}

void OnTrade()
{
   buyPositionsCount = 0;
   sellPositionsCount = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (PositionSelectByTicket(ticket))
      {
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         if (type == POSITION_TYPE_BUY)
            buyPositionsCount++;
         else if (type == POSITION_TYPE_SELL)
            sellPositionsCount++;
      }
   }
}
