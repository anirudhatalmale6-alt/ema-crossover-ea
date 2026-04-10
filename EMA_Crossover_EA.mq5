//+------------------------------------------------------------------+
//|                                          EMA_Crossover_EA.mq5     |
//|                                          Copyright 2026            |
//|                  EMA 9/33 Crossover + Wick Dominance Filter        |
//+------------------------------------------------------------------+
#property copyright "EMA Crossover EA v1.7"
#property version   "1.70"
#property description "EMA 9/33 Crossover + Wick Dominance Filter"
#property description "Designed for Gold (XAUUSD) on M1 timeframe"
#property description "Hidden SL (manual close) + Risk-based lot sizing"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                   |
//+------------------------------------------------------------------+

input group "══════ EMA Settings ══════"
input int      EMA_Fast_Period   = 9;          // Fast EMA Period
input int      EMA_Slow_Period   = 33;         // Slow EMA Period
input int      Max_Candles       = 15;         // Max candles after cross for entry
input int      HighLow_Lookback  = 7;          // Lookback bars for highest/lowest check
input double   TP_Multiplier     = 5.0;        // Take Profit multiplier (x wick distance)

input group "══════ Time Filter (Server Time) ══════"
input int      Market_Open_Hour  = 1;          // Daily Market Open Hour
input int      Market_Open_Min   = 0;          // Daily Market Open Minute
input int      Market_Close_Hour = 23;         // Daily Market Close Hour
input int      Market_Close_Min  = 59;         // Daily Market Close Minute
input int      Open_Delay_Min    = 60;         // Minutes after open to start trading
input int      Close_Before_Min  = 10;         // Minutes before close to exit all trades

input group "══════ Trade Settings ══════"
input double   Risk_Amount       = 10.0;       // Risk Amount per trade (USD)
input int      Magic_Number      = 202601;     // Magic Number
input int      Max_Slippage      = 30;         // Maximum Slippage (points)

//+------------------------------------------------------------------+
//| Global Variables                                                   |
//+------------------------------------------------------------------+

int    g_handleEMAFast;
int    g_handleEMASlow;
CTrade g_trade;

datetime g_lastBarTime    = 0;
int      g_crossDir       = 0;     // 1 = sell signal, -1 = buy signal, 0 = none
int      g_barsSinceCross = 0;
bool     g_tradeTaken     = false;
int      g_prevEMARelation= 0;     // 1 = slow > fast, -1 = slow < fast

//--- Manual SL tracking (hidden stop loss)
double   g_manualSL       = 0;     // Price level to close trade at
int      g_tradeDir       = 0;     // 1 = sell position, -1 = buy position

//+------------------------------------------------------------------+
//| Calculate lot size based on risk amount and SL distance            |
//| lot = RiskAmount / (slDistance / tickSize * tickValue)              |
//+------------------------------------------------------------------+
double CalcLotFromRisk(double slDistancePrice)
{
   if(slDistancePrice <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tickSize <= 0 || tickValue <= 0)
   {
      Print("WARNING: Cannot get tick size/value. Using min lot.");
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   }

   double lossPerLot = (slDistancePrice / tickSize) * tickValue;
   double lot = Risk_Amount / lossPerLot;

   Print(StringFormat("LOT CALC: Risk=$%.2f SLdist=%.5f TickSz=%.5f TickVal=%.2f LossPerLot=%.2f -> Lot=%.2f",
         Risk_Amount, slDistancePrice, tickSize, tickValue, lossPerLot, lot));

   return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   g_handleEMAFast = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEMASlow = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);

   if(g_handleEMAFast == INVALID_HANDLE || g_handleEMASlow == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create EMA indicators");
      return INIT_FAILED;
   }

   //--- Configure trade object
   g_trade.SetExpertMagicNumber(Magic_Number);
   g_trade.SetDeviationInPoints(Max_Slippage);

   //--- Initialize EMA relationship from history
   double emaFast[2], emaSlow[2];
   if(CopyBuffer(g_handleEMAFast, 0, 1, 2, emaFast) >= 2 &&
      CopyBuffer(g_handleEMASlow, 0, 1, 2, emaSlow) >= 2)
   {
      ArraySetAsSeries(emaFast, true);
      ArraySetAsSeries(emaSlow, true);
      if(emaSlow[0] > emaFast[0])      g_prevEMARelation = 1;
      else if(emaSlow[0] < emaFast[0]) g_prevEMARelation = -1;
   }

   //--- Reset manual SL tracking
   g_manualSL  = 0;
   g_tradeDir  = 0;

   Print("EMA Crossover EA v1.7 initialized | EMA ", EMA_Fast_Period, "/", EMA_Slow_Period,
         " | Risk: $", DoubleToString(Risk_Amount, 2),
         " | TP x", DoubleToString(TP_Multiplier, 1), " | Magic: ", Magic_Number,
         " | Hidden SL");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_handleEMAFast != INVALID_HANDLE) IndicatorRelease(g_handleEMAFast);
   if(g_handleEMASlow != INVALID_HANDLE) IndicatorRelease(g_handleEMASlow);
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Always check close time (runs every tick)
   if(IsCloseTime())
   {
      CloseAllTrades();
      g_manualSL = 0;
      g_tradeDir = 0;
      return;
   }

   //--- MANUAL SL CHECK (every tick, hidden from broker)
   CheckManualSL();

   //--- If position was closed (by TP or manual SL), reset tracking
   if(g_manualSL != 0 && !HasOpenPosition())
   {
      g_manualSL = 0;
      g_tradeDir = 0;
   }

   //--- Only process entry logic on new bar
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(barTime == g_lastBarTime) return;
   g_lastBarTime = barTime;

   //--- Get EMA values for bars 0, 1, 2
   double emaFast[3], emaSlow[3];
   if(CopyBuffer(g_handleEMAFast, 0, 0, 3, emaFast) < 3) return;
   if(CopyBuffer(g_handleEMASlow, 0, 0, 3, emaSlow) < 3) return;
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);

   //--- Detect EMA crossover on completed bar (bar 1 vs bar 2)
   int currRelation = 0;
   if(emaSlow[1] > emaFast[1])      currRelation = 1;
   else if(emaSlow[1] < emaFast[1]) currRelation = -1;

   //--- Cross detected when relationship changes
   if(g_prevEMARelation != 0 && currRelation != 0 && g_prevEMARelation != currRelation)
   {
      if(currRelation == 1)
      {
         g_crossDir       = 1;
         g_barsSinceCross = 0;
         g_tradeTaken     = false;
         Print(">>> SIGNAL: EMA", EMA_Slow_Period, " crossed ABOVE EMA", EMA_Fast_Period, " -> SELL");
      }
      else if(currRelation == -1)
      {
         g_crossDir       = -1;
         g_barsSinceCross = 0;
         g_tradeTaken     = false;
         Print(">>> SIGNAL: EMA", EMA_Slow_Period, " crossed BELOW EMA", EMA_Fast_Period, " -> BUY");
      }
   }

   if(currRelation != 0)
      g_prevEMARelation = currRelation;

   //--- Update chart comment
   UpdateChartComment(emaFast[0], emaSlow[0]);

   //--- Increment bar counter for active signal
   if(g_crossDir != 0)
      g_barsSinceCross++;

   //--- Check if we should look for entry
   if(g_crossDir == 0)                         return;
   if(g_barsSinceCross > Max_Candles)           return;
   if(g_tradeTaken)                             return;
   if(!IsTradingTime())                         return;
   if(HasOpenPosition())                        return;

   //--- Analyze the completed candle (bar 1)
   double op  = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double hi  = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double lo  = iLow(_Symbol, PERIOD_CURRENT, 1);
   double cl  = iClose(_Symbol, PERIOD_CURRENT, 1);
   double ema33 = emaSlow[1];

   if(g_crossDir == 1)
      CheckSellEntry(op, hi, lo, cl, ema33);
   else if(g_crossDir == -1)
      CheckBuyEntry(op, hi, lo, cl, ema33);
}

//+------------------------------------------------------------------+
//| MANUAL SL: Check price on every tick and close if crossed          |
//+------------------------------------------------------------------+
void CheckManualSL()
{
   if(g_manualSL == 0 || g_tradeDir == 0) return;
   if(!HasOpenPosition()) return;

   if(g_tradeDir == 1)  // SELL position: close if Ask crosses above candle high
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(ask >= g_manualSL)
      {
         Print(StringFormat("MANUAL SL HIT (Sell): Ask=%.2f >= SL=%.2f -> Closing", ask, g_manualSL));
         CloseAllTrades();
         g_manualSL = 0;
         g_tradeDir = 0;
      }
   }
   else if(g_tradeDir == -1)  // BUY position: close if Bid crosses below candle low
   {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(bid <= g_manualSL)
      {
         Print(StringFormat("MANUAL SL HIT (Buy): Bid=%.2f <= SL=%.2f -> Closing", bid, g_manualSL));
         CloseAllTrades();
         g_manualSL = 0;
         g_tradeDir = 0;
      }
   }
}

//+------------------------------------------------------------------+
//| SELL ENTRY: Wick dominance (upper wick > body AND lower wick)     |
//| Candle must be above 33 EMA                                       |
//|                                                                    |
//| Bear candle: (H-O) > (O-C) AND (H-O) > (C-L)                    |
//| Bull candle: (H-C) > (C-O) AND (H-C) > (O-L)                    |
//+------------------------------------------------------------------+
void CheckSellEntry(double op, double hi, double lo, double cl, double ema33)
{
   //--- Candle High must be the highest of previous N candles
   if(!IsHighestHigh(hi, 1))
      return;

   //--- Candle must be above the 33 EMA
   if(MathMin(op, cl) < ema33)
      return;

   bool isBear = (cl < op);
   double upperWick, body, lowerWick;

   if(isBear)
   {
      upperWick = hi - op;     // (H - O)
      body      = op - cl;     // (O - C)
      lowerWick = cl - lo;     // (C - L)

      //--- (H-O) > (O-C) AND (H-O) > (C-L)
      if(upperWick <= body || upperWick <= lowerWick) return;
   }
   else
   {
      upperWick = hi - cl;     // (H - C)
      body      = cl - op;     // (C - O)
      lowerWick = op - lo;     // (O - L)

      //--- (H-C) > (C-O) AND (H-C) > (O-L)
      if(upperWick <= body || upperWick <= lowerWick) return;
   }

   if(upperWick <= 0) return;

   //--- SL distance = High - Close (for lot calculation)
   double slDistance = hi - cl;
   if(slDistance <= 0) slDistance = hi - op;

   //--- TP = 5x the upper wick distance from entry
   double tp = NormalizeDouble(cl - (TP_Multiplier * upperWick), _Digits);

   //--- Calculate lot from risk amount and SL distance
   double lot = CalcLotFromRisk(slDistance);

   //--- Place sell order (NO SL on order, TP only)
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(g_trade.Sell(lot, _Symbol, price, 0, tp,
      StringFormat("EMA%d/%d Sell | Risk:$%.0f", EMA_Fast_Period, EMA_Slow_Period, Risk_Amount)))
   {
      g_tradeTaken = true;
      g_manualSL   = NormalizeDouble(hi, _Digits);  // Hidden SL at candle High
      g_tradeDir   = 1;
      Print(StringFormat("SELL OPENED: Price=%.2f Lot=%.2f HiddenSL=%.2f TP=%.2f SLdist=%.2f Risk=$%.2f",
            price, lot, g_manualSL, tp, slDistance, Risk_Amount));
   }
   else
   {
      Print("SELL FAILED: Error ", g_trade.ResultRetcode(), " - ", g_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| BUY ENTRY: Wick dominance (lower wick > body AND upper wick)     |
//| Candle must be below 33 EMA                                       |
//|                                                                    |
//| Bear candle: (C-L) > (O-C) AND (C-L) > (H-O)                    |
//| Bull candle: (O-L) > (C-O) AND (O-L) > (H-C)                    |
//+------------------------------------------------------------------+
void CheckBuyEntry(double op, double hi, double lo, double cl, double ema33)
{
   //--- Candle Low must be the lowest of previous N candles
   if(!IsLowestLow(lo, 1))
      return;

   //--- Candle must be below the 33 EMA
   if(MathMax(op, cl) > ema33)
      return;

   bool isBear = (cl < op);
   double upperWick, body, lowerWick;

   if(isBear)
   {
      lowerWick = cl - lo;     // (C - L)
      body      = op - cl;     // (O - C)
      upperWick = hi - op;     // (H - O)

      //--- (C-L) > (O-C) AND (C-L) > (H-O)
      if(lowerWick <= body || lowerWick <= upperWick) return;
   }
   else
   {
      lowerWick = op - lo;     // (O - L)
      body      = cl - op;     // (C - O)
      upperWick = hi - cl;     // (H - C)

      //--- (O-L) > (C-O) AND (O-L) > (H-C)
      if(lowerWick <= body || lowerWick <= upperWick) return;
   }

   if(lowerWick <= 0) return;

   //--- SL distance = Close - Low (for lot calculation)
   double slDistance = cl - lo;
   if(slDistance <= 0) slDistance = op - lo;

   //--- TP = 5x the lower wick distance from entry
   double tp = NormalizeDouble(cl + (TP_Multiplier * lowerWick), _Digits);

   //--- Calculate lot from risk amount and SL distance
   double lot = CalcLotFromRisk(slDistance);

   //--- Place buy order (NO SL on order, TP only)
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(g_trade.Buy(lot, _Symbol, price, 0, tp,
      StringFormat("EMA%d/%d Buy | Risk:$%.0f", EMA_Fast_Period, EMA_Slow_Period, Risk_Amount)))
   {
      g_tradeTaken = true;
      g_manualSL   = NormalizeDouble(lo, _Digits);  // Hidden SL at candle Low
      g_tradeDir   = -1;
      Print(StringFormat("BUY OPENED: Price=%.2f Lot=%.2f HiddenSL=%.2f TP=%.2f SLdist=%.2f Risk=$%.2f",
            price, lot, g_manualSL, tp, slDistance, Risk_Amount));
   }
   else
   {
      Print("BUY FAILED: Error ", g_trade.ResultRetcode(), " - ", g_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Check if candle high is the highest among previous N candles       |
//+------------------------------------------------------------------+
bool IsHighestHigh(double high, int barIndex)
{
   for(int i = barIndex + 1; i <= barIndex + HighLow_Lookback; i++)
   {
      if(iHigh(_Symbol, PERIOD_CURRENT, i) >= high)
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Check if candle low is the lowest among previous N candles         |
//+------------------------------------------------------------------+
bool IsLowestLow(double low, int barIndex)
{
   for(int i = barIndex + 1; i <= barIndex + HighLow_Lookback; i++)
   {
      if(iLow(_Symbol, PERIOD_CURRENT, i) <= low)
         return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Normalize lot size to broker requirements                          |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathMax(minLot, lot);
   lot = MathMin(maxLot, lot);

   if(lotStep > 0)
      lot = MathFloor(lot / lotStep) * lotStep;

   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Check if current time is within trading hours                      |
//+------------------------------------------------------------------+
bool IsTradingTime()
{
   MqlDateTime dt;
   TimeCurrent(dt);

   int nowMin   = dt.hour * 60 + dt.min;
   int openMin  = Market_Open_Hour * 60 + Market_Open_Min;
   int closeMin = Market_Close_Hour * 60 + Market_Close_Min;
   int startMin = openMin + Open_Delay_Min;
   int endMin   = closeMin - Close_Before_Min;

   return (nowMin >= startMin && nowMin < endMin);
}

//+------------------------------------------------------------------+
//| Check if it's time to close all trades                             |
//+------------------------------------------------------------------+
bool IsCloseTime()
{
   MqlDateTime dt;
   TimeCurrent(dt);

   int nowMin   = dt.hour * 60 + dt.min;
   int closeMin = Market_Close_Hour * 60 + Market_Close_Min;
   int exitMin  = closeMin - Close_Before_Min;

   return (nowMin >= exitMin);
}

//+------------------------------------------------------------------+
//| Check for open positions with this magic number                    |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == Magic_Number)
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Close all positions with this magic number                         |
//+------------------------------------------------------------------+
void CloseAllTrades()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == Magic_Number)
         {
            if(g_trade.PositionClose(ticket))
               Print("Position ", ticket, " closed");
            else
               Print("Failed to close position ", ticket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Update chart comment with EA status                                |
//+------------------------------------------------------------------+
void UpdateChartComment(double emaFastVal, double emaSlowVal)
{
   string signal = "None";
   if(g_crossDir == 1)  signal = "SELL";
   if(g_crossDir == -1) signal = "BUY";

   string status = "";
   if(g_tradeTaken)
      status = " [Trade Taken]";
   else if(g_crossDir != 0 && g_barsSinceCross <= Max_Candles)
      status = StringFormat(" [Scanning %d/%d]", g_barsSinceCross, Max_Candles);
   else if(g_crossDir != 0 && g_barsSinceCross > Max_Candles)
      status = " [Window Expired]";

   string tradingStatus = IsTradingTime() ? "ACTIVE" : "PAUSED";
   if(IsCloseTime()) tradingStatus = "CLOSING";

   string slInfo = "";
   if(g_manualSL != 0)
      slInfo = StringFormat("\nHidden SL: %.2f (%s)", g_manualSL, g_tradeDir == 1 ? "Sell" : "Buy");

   Comment(StringFormat(
      "====== EMA Crossover EA v1.7 ======\n"
      "EMA %d: %.2f  |  EMA %d: %.2f\n"
      "Risk per trade: $%.2f\n"
      "Signal: %s%s\n"
      "Trading: %s\n"
      "Open Positions: %s%s\n"
      "===================================",
      EMA_Fast_Period, emaFastVal, EMA_Slow_Period, emaSlowVal,
      Risk_Amount,
      signal, status,
      tradingStatus,
      HasOpenPosition() ? "Yes" : "No",
      slInfo
   ));
}
//+------------------------------------------------------------------+
