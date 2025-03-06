#include <Trade/Trade.mqh>

input double initialLot = 0.01;
input int bbPeriod = 142;
input double bbDeviation = 2;
input int atrPeriod = 86;

input double profitMinMoney = 33;
input double profitAtrDistanceMultiplier = 5;

input int lossRecoveryTrailingStart = 100;
input double lossRecoveryDistanceMultiplier = 4;
input double lossMaxEquityDrawdownMoney = 3000.0;
input bool lossMaxEquityPauseEa = true;

int bandHandle, atrIndicatorHandle;
double atrData[], upperBB[], middleBB[], lowerBB[];
double buyEntry = 0.0, sellEntry = 0.0;

double lastBuyPrice = 0.0, lastSellPrice = 0.0;
int buyRecoveryLevel = 0, sellRecoveryLevel = 0;
datetime lastBarTime = 0;
CTrade trade;

int OnInit()
{
   atrIndicatorHandle = iATR(_Symbol, _Period, atrPeriod);
   bandHandle = iBands(_Symbol, _Period, bbPeriod, 0, bbDeviation, PRICE_CLOSE);

   ArraySetAsSeries(atrData, true);
   ArraySetAsSeries(upperBB, true);
   ArraySetAsSeries(middleBB, true);
   ArraySetAsSeries(lowerBB, true);

   return INIT_SUCCEEDED;
}

void OnTick()
{
   if (lossMaxEquityPauseEa &&
       (AccountInfoDouble(ACCOUNT_BALANCE) - AccountInfoDouble(ACCOUNT_EQUITY)) >= lossMaxEquityDrawdownMoney)
   {
      return;
   }

   updateIndicators();
   manageVirtualStops();

   if (PositionsTotal() == 0)
   {
      buyRecoveryLevel = 0; // Reset both levels
      sellRecoveryLevel = 0;
   }

   bool newBar = isNewBar();
   if (newBar)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);

      if (checkEntryConditions() && dt.day_of_week != 5)
      {
         if (positionsTotalByType(POSITION_TYPE_BUY) == 0)
         {
            double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            buyEntry = price;
            trade.Buy(initialLot, _Symbol, price, 0, 0, "Initial Buy");
            lastBuyPrice = buyEntry;
         }

         if (positionsTotalByType(POSITION_TYPE_SELL) == 0)
         {
            double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            sellEntry = price;
            trade.Sell(initialLot, _Symbol, price, 0, 0, "Initial Sell");
            lastSellPrice = sellEntry;
         }

         lastBarTime = iTime(_Symbol, _Period, 0);
      }
   }

   checkForRecoveries();
}

void manageVirtualStops()
{
   // Check and close BUY positions if profit target met
   double buyProfit = calculateTotalProfit(POSITION_TYPE_BUY);
   if (buyProfit >= profitMinMoney)
   {
      closeAllPositions(POSITION_TYPE_BUY);
   }

   // Check and close SELL positions if profit target met
   double sellProfit = calculateTotalProfit(POSITION_TYPE_SELL);
   if (sellProfit >= profitMinMoney)
   {
      closeAllPositions(POSITION_TYPE_SELL);
   }
}

bool isNewBar()
{
   datetime currentBar = iTime(_Symbol, _Period, 0);
   return (currentBar != lastBarTime);
}

void updateIndicators()
{
   ArrayResize(middleBB, 3);
   ArrayResize(upperBB, 3);
   ArrayResize(lowerBB, 3);
   ArrayResize(atrData, 3);
   CopyBuffer(bandHandle, 0, 0, 3, middleBB);
   CopyBuffer(bandHandle, 1, 0, 3, upperBB);
   CopyBuffer(bandHandle, 2, 0, 3, lowerBB);
   CopyBuffer(atrIndicatorHandle, 0, 0, 3, atrData);
}

bool checkEntryConditions()
{
   if (atrData[0] > atrData[1] * lossRecoveryDistanceMultiplier)
      return false;

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool priceNearMiddle = MathAbs(price - middleBB[0]) <= 2 * _Point;
   bool momentum = MathAbs(middleBB[0] - middleBB[1]) < _Point * 2;
   return priceNearMiddle && momentum;
}

void checkForRecoveries()
{
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Check for BUY recovery (price hits lower band)
   if (currentBid <= lowerBB[0] && lastBuyPrice > 0)
   {
      double requiredDistance = (lossRecoveryTrailingStart * _Point) * (buyRecoveryLevel + 1);
      if ((lastBuyPrice - currentBid) >= requiredDistance)
      {
         openTrade(ORDER_TYPE_BUY, currentAsk);
         buyRecoveryLevel++;
      }
   }

   // Check for SELL recovery (price hits upper band)
   if (currentBid >= upperBB[0] && lastSellPrice > 0)
   {
      double requiredDistance = (lossRecoveryTrailingStart * _Point) * (sellRecoveryLevel + 1);
      if ((currentBid - lastSellPrice) >= requiredDistance)
      {
         openTrade(ORDER_TYPE_SELL, currentBid);
         sellRecoveryLevel++;
      }
   }
}

void openTrade(ENUM_ORDER_TYPE type, double price)
{
   double lotSize;
   if (type == ORDER_TYPE_BUY)
   {
      lotSize = initialLot * MathPow(2, buyRecoveryLevel);
      trade.Buy(lotSize, _Symbol, price, 0, 0, "Recovery Buy Lvl" + string(buyRecoveryLevel + 1));
      lastBuyPrice = price;
   }
   else
   {
      lotSize = initialLot * MathPow(2, sellRecoveryLevel);
      trade.Sell(lotSize, _Symbol, price, 0, 0, "Recovery Sell Lvl" + string(sellRecoveryLevel + 1));
      lastSellPrice = price;
   }
}

double calculateTotalProfit(ENUM_POSITION_TYPE type)
{
   double totalProfit = 0.0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_TYPE) == type)
      {
         totalProfit += PositionGetDouble(POSITION_PROFIT);
      }
   }
   return totalProfit;
}

int positionsTotalByType(ENUM_POSITION_TYPE type)
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

void closeAllPositions(ENUM_POSITION_TYPE type)
{
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_TYPE) == type)
         trade.PositionClose(ticket);
   }

   if (type == POSITION_TYPE_BUY)
   {
      buyRecoveryLevel = 0;
   }
   else if (type == POSITION_TYPE_SELL)
   {
      sellRecoveryLevel = 0;
   }
}
