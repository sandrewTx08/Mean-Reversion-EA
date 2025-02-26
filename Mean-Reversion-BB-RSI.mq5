#include <Trade/Trade.mqh>

//--- Input Parameters
input double Initial_Lot = 0.01;
input int BB_Period = 200;
input double BB_Deviation = 2.0;
input int Recovery_Start = 100;                  // Initial recovery distance in points
input int Recovery_Step = 100;                   // Additional recovery distance in points for each level
input double Recovery_Distance_Multiplier = 1.5; // Multiplier for recovery distance at each level
input int RSI_Period = 14;
input int RSI_Overbought = 92;
input int RSI_Oversold = 18;
input int Trailing_Start = 110;                       // Trailing stop activation (points)
input int Trailing_Step = 100;                        // Trailing stop step (points)
input double Max_Equity_Drawdown_Money = 2000.0;      // Maximum equity risk in money
input int ATR_Period = 14;                            // ATR Period
input double ATR_Multiplier_Gain = 2.0;               // ATR Multiplier for Gain
input double Recovery_Distance_Multiplier_Loss = 2.0; // Multiplier for recovery distance at loss

//--- Global Variables
int bbHandle,
    rsiHandle, atrHandle;
double atrBuffer[], upperBand[], middleBand[], lowerBand[], rsiBuffer[];
double buyEntryPrice, sellEntryPrice;
double buyExtremePrice = 0.0;  // Tracks highest bid for buys
double sellExtremePrice = 0.0; // Tracks lowest ask for sells

//--- Trade Tracking
double lastBuyTradePrice, lastSellTradePrice;
int RecoveryLevel = 0; // Unified recovery level counter
ulong buyTickets[], sellTickets[];
datetime lastTradeTime;
CTrade trade;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   atrHandle = iATR(_Symbol, _Period, ATR_Period);
   bbHandle = iBands(_Symbol, _Period, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
   rsiHandle = iRSI(_Symbol, _Period, RSI_Period, PRICE_CLOSE);

   ArraySetAsSeries(atrBuffer, true);
   ArraySetAsSeries(upperBand, true);
   ArraySetAsSeries(middleBand, true);
   ArraySetAsSeries(lowerBand, true);
   ArraySetAsSeries(rsiBuffer, true);

   return (INIT_SUCCEEDED);
}

void OnTick()
{
   UpdateIndicators();

   if (AccountInfoDouble(ACCOUNT_EQUITY) <= Max_Equity_Drawdown_Money)
   {
      CloseAllPositions(POSITION_TYPE_BUY);
      CloseAllPositions(POSITION_TYPE_SELL);
      ExpertRemove();
      return;
   }

   ManageVirtualStops();

   CheckProfitCoverage(); // New profit coverage check

   if (PositionsTotal() == 0)
   {
      RecoveryLevel = 0;
      buyExtremePrice = 0.0;
      sellExtremePrice = 0.0;
      ArrayFree(buyTickets);
      ArrayFree(sellTickets);
   }

   bool isNewBar = NewBar();

   if (isNewBar)
   {
      if (PositionsTotal() == 0 && CheckEntryConditions())
      {
         PlaceInitialOrders();
         lastTradeTime = iTime(_Symbol, _Period, 0);
      }
   }

   CheckForRecoveries();
}

void CheckProfitCoverage()
{
   int buyPositions = PositionsTotalByType(POSITION_TYPE_BUY);
   int sellPositions = PositionsTotalByType(POSITION_TYPE_SELL);

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

   // Check if sell profits cover buy losses
   if (sellProfit > 0 && buyProfit < 0 && sellProfit >= (-buyProfit))
   {
      CloseAllPositions(POSITION_TYPE_BUY);
      CloseAllPositions(POSITION_TYPE_SELL);
   }
   // Check if buy profits cover sell losses
   else if (buyProfit > 0 && sellProfit < 0 && buyProfit >= (-sellProfit))
   {
      CloseAllPositions(POSITION_TYPE_BUY);
      CloseAllPositions(POSITION_TYPE_SELL);
   }
}

void ManageVirtualStops()
{
   if (ArraySize(atrBuffer) == 0)
   {
      UpdateIndicators();
      return;
   }

   double currentATR = atrBuffer[0];

   if (PositionsTotalByType(POSITION_TYPE_BUY) > 0)
   {
      double breakeven = CalculateBreakeven(POSITION_TYPE_BUY);
      double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      buyExtremePrice = (buyExtremePrice == 0.0) ? currentBid : fmax(currentBid, buyExtremePrice);

      // ATR multiplied breakeven and steps for gains
      double atrBreakeven = breakeven + (currentATR * ATR_Multiplier_Gain);
      double atrTrailingStep = currentATR * Recovery_Distance_Multiplier;

      if (currentBid >= atrBreakeven)
      {
         double virtualSL = buyExtremePrice - atrTrailingStep;
         if (currentBid <= virtualSL)
            CloseAllPositions(POSITION_TYPE_BUY);
      }
   }

   if (PositionsTotalByType(POSITION_TYPE_SELL) > 0)
   {
      double breakeven = CalculateBreakeven(POSITION_TYPE_SELL);
      double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      sellExtremePrice = (sellExtremePrice == 0.0) ? currentAsk : fmin(currentAsk, sellExtremePrice);

      // ATR multiplied breakeven and steps for losses
      double atrBreakeven = breakeven - (currentATR * ATR_Multiplier_Gain);
      double atrTrailingStep = currentATR * Recovery_Distance_Multiplier_Loss;

      if (currentAsk <= atrBreakeven)
      {
         double virtualSL = sellExtremePrice + atrTrailingStep;
         if (currentAsk >= virtualSL)
            CloseAllPositions(POSITION_TYPE_SELL);
      }
   }
}

//+------------------------------------------------------------------+
//| Check for new candle                                             |
//+------------------------------------------------------------------+
bool NewBar()
{
   datetime currentBar = iTime(_Symbol, _Period, 0);
   return currentBar != lastTradeTime;
}

void UpdateIndicators()
{
   ArrayResize(middleBand, 3);
   ArrayResize(upperBand, 3);
   ArrayResize(lowerBand, 3);
   ArrayResize(rsiBuffer, 3);
   ArrayResize(atrBuffer, 3);

   CopyBuffer(bbHandle, 0, 0, 3, middleBand);
   CopyBuffer(bbHandle, 1, 0, 3, upperBand);
   CopyBuffer(bbHandle, 2, 0, 3, lowerBand);
   CopyBuffer(rsiHandle, 0, 0, 3, rsiBuffer);
   CopyBuffer(atrHandle, 0, 0, 3, atrBuffer);
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
//| Unified recovery system with distance coordination               |
//+------------------------------------------------------------------+
bool CheckEntryConditions()
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   // Check if price is near middle band for initial entry
   return MathAbs(price - middleBand[0]) <= 2 * _Point;
}

void CheckForRecoveries()
{
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentATR = atrBuffer[0];
   double requiredDistance = currentATR * Recovery_Distance_Multiplier_Loss * (RecoveryLevel + 1);

   if ((lastBuyTradePrice - currentPrice) >= requiredDistance)
   {
      OpenHedgeTrade(ORDER_TYPE_BUY, SymbolInfoDouble(_Symbol, SYMBOL_ASK));
      RecoveryLevel++;
   }

   if ((currentPrice - lastSellTradePrice) >= requiredDistance)
   {
      OpenHedgeTrade(ORDER_TYPE_SELL, SymbolInfoDouble(_Symbol, SYMBOL_BID));
      RecoveryLevel++;
   }
}

//+------------------------------------------------------------------+
//| Check buy side recoveries                                        |
//+------------------------------------------------------------------+
void CheckBuyRecoveries()
{
   if (PositionsTotalByType(POSITION_TYPE_BUY) == 0)
      return;

   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   // Calculate the effective recovery distance for the current recovery level.
   // The trailing offset is added to both the initial and subsequent step distances.
   double requiredDistance = CalculateRecoveryDistance(RecoveryLevel);

   if ((lastBuyTradePrice - currentBid) >= requiredDistance)
   {
      if (rsiBuffer[0] < RSI_Oversold && currentBid < lowerBand[0])
      {
         // Open hedge recovery trade with the unified recovery level
         OpenRecoveryTrade(ORDER_TYPE_SELL, SymbolInfoDouble(_Symbol, SYMBOL_BID), RecoveryLevel + 1);
         RecoveryLevel++;
         lastTradeTime = iTime(_Symbol, _Period, 0);
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
   double requiredDistance = CalculateRecoveryDistance(RecoveryLevel);

   if ((currentAsk - lastSellTradePrice) >= requiredDistance)
   {
      if (rsiBuffer[0] > RSI_Overbought && currentAsk > upperBand[0])
      {
         OpenRecoveryTrade(ORDER_TYPE_BUY, SymbolInfoDouble(_Symbol, SYMBOL_ASK), RecoveryLevel + 1);
         RecoveryLevel++;
         lastTradeTime = iTime(_Symbol, _Period, 0);
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate recovery distance based on level                       |
//| This function adds the same trailing offset (Trailing_Step) to both |
//| the initial recovery distance (Recovery_Start) and the subsequent   |
//| step distances to keep the hedge gap constant.                     |
//+------------------------------------------------------------------+
double CalculateRecoveryDistance(int level)
{
   double recoveryBase = (level == 0) ? Recovery_Start : (Recovery_Step * MathPow(Recovery_Distance_Multiplier, level));
   return (recoveryBase + Trailing_Step) * _Point;
}

//+------------------------------------------------------------------+
//| Open recovery trade in opposite direction                        |
//+------------------------------------------------------------------+
void OpenRecoveryTrade(ENUM_ORDER_TYPE type, double price, int level)
{
   double lotSize = Initial_Lot * MathPow(2, level);

   // Place recovery (hedge) order at the current price.
   if (type == ORDER_TYPE_SELL)
   {
      trade.Sell(lotSize, _Symbol, price, 0, 0, "Recovery Sell Lvl" + string(level));
      ArrayResize(sellTickets, ArraySize(sellTickets) + 1);
      sellTickets[ArraySize(sellTickets) - 1] = trade.ResultOrder();
      lastSellTradePrice = price;
   }
   else
   {
      trade.Buy(lotSize, _Symbol, price, 0, 0, "Recovery Buy Lvl" + string(level));
      ArrayResize(buyTickets, ArraySize(buyTickets) + 1);
      buyTickets[ArraySize(buyTickets) - 1] = trade.ResultOrder();
      lastBuyTradePrice = price;
   }
}

//+------------------------------------------------------------------+
//| Calculate breakeven price for position group                     |
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
//| Open hedge trade in opposite direction                           |
//+------------------------------------------------------------------+
void OpenHedgeTrade(ENUM_ORDER_TYPE type, double price)
{
   double lotSize = Initial_Lot * MathPow(2, RecoveryLevel);

   if (type == ORDER_TYPE_SELL)
   {
      trade.Sell(lotSize, _Symbol, price, 0, 0, "Hedge Sell Lvl" + string(RecoveryLevel + 1));
      ArrayResize(sellTickets, ArraySize(sellTickets) + 1);
      sellTickets[ArraySize(sellTickets) - 1] = trade.ResultOrder();
      lastSellTradePrice = price;
   }
   else
   {
      trade.Buy(lotSize, _Symbol, price, 0, 0, "Hedge Buy Lvl" + string(RecoveryLevel + 1));
      ArrayResize(buyTickets, ArraySize(buyTickets) + 1);
      buyTickets[ArraySize(buyTickets) - 1] = trade.ResultOrder();
      lastBuyTradePrice = price;
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

   // Reset tracking variables for the closed side
   if (type == POSITION_TYPE_BUY)
      buyExtremePrice = 0.0;
   else if (type == POSITION_TYPE_SELL)
      sellExtremePrice = 0.0;

   // Also reset the unified RecoveryLevel
   RecoveryLevel = 0;
}
