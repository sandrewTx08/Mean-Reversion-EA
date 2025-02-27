#include <Trade/Trade.mqh>

input double initialLot = 0.01;
input int bbPeriod = 200;
input double bbDeviation = 2.0;
input int recoveryStart = 100;
input int recoveryStep = 100;
input double recoveryDistanceMultiplier = 1.5;
input int rsiPeriod = 14;
input int rsiOverbought = 92;
input int rsiOversold = 18;
input int trailingStart = 110;
input int trailingStep = 100;
input double maxEquityDrawdownMoney = 2000.0;
input int atrPeriod = 14;
input double atrMultiplierGain = 2.0;
input double recoveryDistanceMultiplierLoss = 2.0;

int bandHandle, rsiHandle, atrIndicatorHandle;
double atrData[], upperBB[], middleBB[], lowerBB[], rsiData[];
double buyEntry = 0.0, sellEntry = 0.0;
double maxBuyBid = 0.0, minSellPrice = 0.0;

double lastBuyPrice = 0.0, lastSellPrice = 0.0;
int recoveryLevel = 0;
ulong buyOrderTickets[], sellOrderTickets[];
datetime lastBarTime = 0;
CTrade trade;

int OnInit()
{
   atrIndicatorHandle = iATR(_Symbol, _Period, atrPeriod);
   bandHandle = iBands(_Symbol, _Period, bbPeriod, 0, bbDeviation, PRICE_CLOSE);
   rsiHandle = iRSI(_Symbol, _Period, rsiPeriod, PRICE_CLOSE);

   ArraySetAsSeries(atrData, true);
   ArraySetAsSeries(upperBB, true);
   ArraySetAsSeries(middleBB, true);
   ArraySetAsSeries(lowerBB, true);
   ArraySetAsSeries(rsiData, true);

   return INIT_SUCCEEDED;
}

void OnTick()
{
   if ((AccountInfoDouble(ACCOUNT_BALANCE) - AccountInfoDouble(ACCOUNT_EQUITY)) >= maxEquityDrawdownMoney)
   {
      closeAllPositions(POSITION_TYPE_BUY);
      closeAllPositions(POSITION_TYPE_SELL);
      ExpertRemove();
      return;
   }

   updateIndicators();
   manageVirtualStops();
   checkProfitCoverage();

   if (PositionsTotal() == 0)
   {
      recoveryLevel = 0;
      maxBuyBid = 0.0;
      minSellPrice = 0.0;
      ArrayFree(buyOrderTickets);
      ArrayFree(sellOrderTickets);
   }

   bool newBar = isNewBar();
   if (newBar)
   {
      if (PositionsTotal() == 0 && checkEntryConditions())
      {
         placeInitialOrders();
         lastBarTime = iTime(_Symbol, _Period, 0);
      }
   }
   checkForRecoveries();
}

void checkProfitCoverage()
{
   int buyPositions = positionsTotalByType(POSITION_TYPE_BUY);
   int sellPositions = positionsTotalByType(POSITION_TYPE_SELL);
   if (buyPositions == 0 || sellPositions == 0)
      return;

   double buyProfit = 0.0, sellProfit = 0.0;
   for (int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if (PositionSelectByTicket(ticket))
      {
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double profit = PositionGetDouble(POSITION_PROFIT);
         if (type == POSITION_TYPE_BUY)
            buyProfit += profit;
         else
            sellProfit += profit;
      }
   }
   if (sellProfit > 0 && buyProfit < 0 && sellProfit >= (-buyProfit))
   {
      closeAllPositions(POSITION_TYPE_BUY);
      closeAllPositions(POSITION_TYPE_SELL);
   }
   else if (buyProfit > 0 && sellProfit < 0 && buyProfit >= (-sellProfit))
   {
      closeAllPositions(POSITION_TYPE_BUY);
      closeAllPositions(POSITION_TYPE_SELL);
   }
}

void manageVirtualStops()
{
   if (ArraySize(atrData) == 0)
   {
      updateIndicators();
      return;
   }
   double currentATR = atrData[0];
   if (positionsTotalByType(POSITION_TYPE_BUY) > 0)
   {
      double breakeven = calcBreakeven(POSITION_TYPE_BUY);
      double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      maxBuyBid = (maxBuyBid == 0.0) ? currentBid : fmax(currentBid, maxBuyBid);
      double atrBreakeven = breakeven + (currentATR * atrMultiplierGain);
      double atrTrailingStep = currentATR * recoveryDistanceMultiplier;
      if (currentBid >= atrBreakeven)
      {
         double virtualSL = maxBuyBid - atrTrailingStep;
         if (currentBid <= virtualSL)
            closeAllPositions(POSITION_TYPE_BUY);
      }
   }
   if (positionsTotalByType(POSITION_TYPE_SELL) > 0)
   {
      double breakeven = calcBreakeven(POSITION_TYPE_SELL);
      double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      minSellPrice = (minSellPrice == 0.0) ? currentAsk : fmin(currentAsk, minSellPrice);
      double atrBreakeven = breakeven - (currentATR * atrMultiplierGain);
      double atrTrailingStep = currentATR * recoveryDistanceMultiplierLoss;
      if (currentAsk <= atrBreakeven)
      {
         double virtualSL = minSellPrice + atrTrailingStep;
         if (currentAsk >= virtualSL)
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
   ArrayResize(middleBB, 3);
   ArrayResize(upperBB, 3);
   ArrayResize(lowerBB, 3);
   ArrayResize(rsiData, 3);
   ArrayResize(atrData, 3);
   CopyBuffer(bandHandle, 0, 0, 3, middleBB);
   CopyBuffer(bandHandle, 1, 0, 3, upperBB);
   CopyBuffer(bandHandle, 2, 0, 3, lowerBB);
   CopyBuffer(rsiHandle, 0, 0, 3, rsiData);
   CopyBuffer(atrIndicatorHandle, 0, 0, 3, atrData);
}

void placeInitialOrders()
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   buyEntry = price;
   trade.Buy(initialLot, _Symbol, price, 0, 0, "Initial Buy");
   ArrayResize(buyOrderTickets, ArraySize(buyOrderTickets) + 1);
   buyOrderTickets[ArraySize(buyOrderTickets) - 1] = trade.ResultOrder();

   price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   sellEntry = price;
   trade.Sell(initialLot, _Symbol, price, 0, 0, "Initial Sell");
   ArrayResize(sellOrderTickets, ArraySize(sellOrderTickets) + 1);
   sellOrderTickets[ArraySize(sellOrderTickets) - 1] = trade.ResultOrder();

   lastBuyPrice = buyEntry;
   lastSellPrice = sellEntry;
   lastBarTime = iTime(_Symbol, _Period, 0);
}

bool checkEntryConditions()
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool priceNearMiddle = MathAbs(price - middleBB[0]) <= 2 * _Point;
   return priceNearMiddle;
}

void checkForRecoveries()
{
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentATR = atrData[0];
   double requiredDistance = currentATR * recoveryDistanceMultiplier * (recoveryLevel + 1);
   if ((lastBuyPrice - currentBid) >= requiredDistance)
   {
      openHedgeTrade(ORDER_TYPE_BUY, currentAsk);
      recoveryLevel++;
   }
   if ((currentBid - lastSellPrice) >= requiredDistance)
   {
      openHedgeTrade(ORDER_TYPE_SELL, currentBid);
      recoveryLevel++;
   }
}

void checkBuyRecoveries()
{
   if (positionsTotalByType(POSITION_TYPE_BUY) == 0)
      return;
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double requiredDistance = calcRecoveryDistance(recoveryLevel);
   if ((lastBuyPrice - currentBid) >= requiredDistance)
   {
      if (rsiData[0] < rsiOversold && currentBid < lowerBB[0])
      {
         openRecoveryTrade(ORDER_TYPE_SELL, currentBid, recoveryLevel + 1);
         recoveryLevel++;
         lastBarTime = iTime(_Symbol, _Period, 0);
      }
   }
}

void checkSellRecoveries()
{
   if (positionsTotalByType(POSITION_TYPE_SELL) == 0)
      return;
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double requiredDistance = calcRecoveryDistance(recoveryLevel);
   if ((currentAsk - lastSellPrice) >= requiredDistance)
   {
      if (rsiData[0] > rsiOverbought && currentAsk > upperBB[0])
      {
         openRecoveryTrade(ORDER_TYPE_BUY, currentAsk, recoveryLevel + 1);
         recoveryLevel++;
         lastBarTime = iTime(_Symbol, _Period, 0);
      }
   }
}

double calcRecoveryDistance(int level)
{
   double recoveryBase = (level == 0) ? recoveryStart : (recoveryStep * MathPow(recoveryDistanceMultiplier, level));
   return (recoveryBase + trailingStep) * _Point;
}

void openRecoveryTrade(ENUM_ORDER_TYPE type, double price, int level)
{
   double lotSize = initialLot * MathPow(2, level);
   if (type == ORDER_TYPE_SELL)
   {
      trade.Sell(lotSize, _Symbol, price, 0, 0, "Recovery Sell Lvl" + string(level));
      ArrayResize(sellOrderTickets, ArraySize(sellOrderTickets) + 1);
      sellOrderTickets[ArraySize(sellOrderTickets) - 1] = trade.ResultOrder();
      lastSellPrice = price;
   }
   else
   {
      trade.Buy(lotSize, _Symbol, price, 0, 0, "Recovery Buy Lvl" + string(level));
      ArrayResize(buyOrderTickets, ArraySize(buyOrderTickets) + 1);
      buyOrderTickets[ArraySize(buyOrderTickets) - 1] = trade.ResultOrder();
      lastBuyPrice = price;
   }
}

double calcBreakeven(ENUM_POSITION_TYPE type)
{
   double totalVolume = 0.0, weightedPrice = 0.0;
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
   return (totalVolume > 0.0) ? weightedPrice / totalVolume : 0.0;
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

void openHedgeTrade(ENUM_ORDER_TYPE type, double price)
{
   double lotSize = initialLot * MathPow(2, recoveryLevel);
   if (type == ORDER_TYPE_SELL)
   {
      trade.Sell(lotSize, _Symbol, price, 0, 0, "Hedge Sell Lvl" + string(recoveryLevel + 1));
      ArrayResize(sellOrderTickets, ArraySize(sellOrderTickets) + 1);
      sellOrderTickets[ArraySize(sellOrderTickets) - 1] = trade.ResultOrder();
      lastSellPrice = price;
   }
   else
   {
      trade.Buy(lotSize, _Symbol, price, 0, 0, "Hedge Buy Lvl" + string(recoveryLevel + 1));
      ArrayResize(buyOrderTickets, ArraySize(buyOrderTickets) + 1);
      buyOrderTickets[ArraySize(buyOrderTickets) - 1] = trade.ResultOrder();
      lastBuyPrice = price;
   }
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
      maxBuyBid = 0.0;
   else if (type == POSITION_TYPE_SELL)
      minSellPrice = 0.0;
   recoveryLevel = 0;
}
