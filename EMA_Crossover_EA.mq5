//+------------------------------------------------------------------+
//|                                          EMA_Crossover_EA.mq5     |
//|                                          Copyright 2026            |
//|                  EMA 9/33 Crossover + Wick Dominance Filter        |
//+------------------------------------------------------------------+
#property copyright "EMA Crossover EA v1.8"
#property version   "1.80"
#property description "EMA 9/33 Crossover + Wick Dominance Filter"
#property description "Designed for Gold (XAUUSD) on M1 timeframe"
#property description "Hidden SL + Risk-based lot + Multi-trade per signal"

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
input double   SL_Buffer_Points  = 3.0;        // Points buffer above/below candle for SL close
input int      Magic_Number      = 202601;     // Magic Number
input int      Max_Slippage      = 30;         // Maximum Slippage (points)

//+------------------------------------------------------------------+
//| Trade tracking structure (for multiple positions)                   |
//+------------------------------------------------------------------+
struct TradeInfo
{
   ulong  ticket;
   double slLevel;
   int    direction;   // 1 = sell, -1 = buy
};

//+------------------------------------------------------------------+
//| Global Variables                                                   |
//+------------------------------------------------------------------+

int    g_handleEMAFast;
int    g_handleEMASlow;
CTrade g_trade;

datetime g_lastBarTime    = 0;
int      g_crossDir       = 0;     // 1 = sell signal, -1 = buy signal, 0 = none
int      g_barsSinceCross = 0;
int      g_prevEMARelation= 0;     // 1 = slow > fast, -1 = slow < fast

TradeInfo g_trades[];
int       g_tradeCount = 0;

//+------------------------------------------------------------------+
//| Calculate lot size using OrderCalcProfit (broker-accurate)          |
//+------------------------------------------------------------------+
double CalcLotFromRisk(double entryPrice, double slPrice, bool isSell)
{
   double profit = 0;
   ENUM_ORDER_TYPE orderType = isSell ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

   if(!OrderCalcProfit(orderType, _Symbol, 1.0, entryPrice, slPrice, profit))
   {
      Print("WARNING: OrderCalcProfit failed. Using fallback.");
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tickSize > 0 && tickValue > 0)
      {
         double slDist = MathAbs(entryPrice - slPrice);
         double lossPerLot = (slDist / tickSize) * tickValue;
         if(lossPerLot > 0)
            return NormalizeLot(Risk_Amount / lossPerLot);
      }
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   }

   double lossPerLot = MathAbs(profit);
   if(lossPerLot <= 0)
   {
      Print("WARNING: Loss per lot = 0. Using min lot.");
      return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   }

   double lot = Risk_Amount / lossPerLot;

   Print(StringFormat("LOT CALC: Risk=$%.2f Entry=%.2f SL=%.2f LossPerLot=$%.2f -> Lot=%.4f",
         Risk_Amount, entryPrice, slPrice, lossPerLot, lot));

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

   g_trade.SetExpertMagicNumber(Magic_Number);
   g_trade.SetDeviationInPoints(Max_Slippage);

   double emaFast[2], emaSlow[2];
   if(CopyBuffer(g_handleEMAFast, 0, 1, 2, emaFast) >= 2 &&
      CopyBuffer(g_handleEMASlow, 0, 1, 2, emaSlow) >= 2)
   {
      ArraySetAsSeries(emaFast, true);
      ArraySetAsSeries(emaSlow, true);
      if(emaSlow[0] > emaFast[0])      g_prevEMARelation = 1;
      else if(emaSlow[0] < emaFast[0]) g_prevEMARelation = -1;
   }

   g_tradeCount = 0;
   ArrayResize(g_trades, 0);

   Print("EMA Crossover EA v1.8 initialized | EMA ", EMA_Fast_Period, "/", EMA_Slow_Period,
         " | Risk: $", DoubleToString(Risk_Amount, 2),
         " | SL Buffer: ", DoubleToString(SL_Buffer_Points, 1), " pts",
         " | TP x", DoubleToString(TP_Multiplier, 1), " | Magic: ", Magic_Number,
         " | Multi-trade per signal");

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
   if(IsCloseTime())
   {
      CloseAllTrades();
      g_tradeCount = 0;
      ArrayResize(g_trades, 0);
      return;
   }

   CheckManualSL();
   CleanupClosedTrades();

   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(barTime == g_lastBarTime) return;
   g_lastBarTime = barTime;

   double emaFast[3], emaSlow[3];
   if(CopyBuffer(g_handleEMAFast, 0, 0, 3, emaFast) < 3) return;
   if(CopyBuffer(g_handleEMASlow, 0, 0, 3, emaSlow) < 3) return;
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);

   int currRelation = 0;
   if(emaSlow[1] > emaFast[1])      currRelation = 1;
   else if(emaSlow[1] < emaFast[1]) currRelation = -1;

   if(g_prevEMARelation != 0 && currRelation != 0 && g_prevEMARelation != currRelation)
   {
      if(currRelation == 1)
      {
         g_crossDir       = 1;
         g_barsSinceCross = 0;
         Print(">>> SIGNAL: EMA", EMA_Slow_Period, " crossed ABOVE EMA", EMA_Fast_Period, " -> SELL");
      }
      else if(currRelation == -1)
      {
         g_crossDir       = -1;
         g_barsSinceCross = 0;
         Print(">>> SIGNAL: EMA", EMA_Slow_Period, " crossed BELOW EMA", EMA_Fast_Period, " -> BUY");
      }
   }

   if(currRelation != 0)
      g_prevEMARelation = currRelation;

   UpdateChartComment(emaFast[0], emaSlow[0]);

   if(g_crossDir != 0)
      g_barsSinceCross++;

   if(g_crossDir == 0)               return;
   if(g_barsSinceCross > Max_Candles) return;
   if(!IsTradingTime())               return;

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
//| MANUAL SL: Check each tracked position against its SL level       |
//+------------------------------------------------------------------+
void CheckManualSL()
{
   if(g_tradeCount == 0) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   for(int i = g_tradeCount - 1; i >= 0; i--)
   {
      if(g_trades[i].direction == 1)  // SELL: close if Ask >= SL
      {
         if(ask >= g_trades[i].slLevel)
         {
            Print(StringFormat("MANUAL SL HIT (Sell #%d): Ask=%.2f >= SL=%.2f",
                  g_trades[i].ticket, ask, g_trades[i].slLevel));
            g_trade.PositionClose(g_trades[i].ticket);
            RemoveTrade(i);
         }
      }
      else if(g_trades[i].direction == -1)  // BUY: close if Bid <= SL
      {
         if(bid <= g_trades[i].slLevel)
         {
            Print(StringFormat("MANUAL SL HIT (Buy #%d): Bid=%.2f <= SL=%.2f",
                  g_trades[i].ticket, bid, g_trades[i].slLevel));
            g_trade.PositionClose(g_trades[i].ticket);
            RemoveTrade(i);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Remove trade from tracking array                                   |
//+------------------------------------------------------------------+
void RemoveTrade(int index)
{
   for(int i = index; i < g_tradeCount - 1; i++)
      g_trades[i] = g_trades[i + 1];
   g_tradeCount--;
   ArrayResize(g_trades, g_tradeCount);
}

//+------------------------------------------------------------------+
//| Remove trades closed by TP or externally                           |
//+------------------------------------------------------------------+
void CleanupClosedTrades()
{
   for(int i = g_tradeCount - 1; i >= 0; i--)
   {
      bool found = false;
      for(int j = PositionsTotal() - 1; j >= 0; j--)
      {
         if(PositionGetTicket(j) == g_trades[i].ticket)
         {
            found = true;
            break;
         }
      }
      if(!found)
         RemoveTrade(i);
   }
}

//+------------------------------------------------------------------+
//| Add trade to tracking array                                        |
//+------------------------------------------------------------------+
void AddTrade(ulong ticket, double slLevel, int direction)
{
   g_tradeCount++;
   ArrayResize(g_trades, g_tradeCount);
   g_trades[g_tradeCount - 1].ticket    = ticket;
   g_trades[g_tradeCount - 1].slLevel   = slLevel;
   g_trades[g_tradeCount - 1].direction = direction;
}

//+------------------------------------------------------------------+
//| SELL ENTRY                                                         |
//| Bear candle: (H-O) > (O-C) AND (H-O) > (C-L)                    |
//| Bull candle: (H-C) > (C-O) AND (H-C) > (O-L)                    |
//+------------------------------------------------------------------+
void CheckSellEntry(double op, double hi, double lo, double cl, double ema33)
{
   if(!IsHighestHigh(hi, 1))
      return;

   if(MathMin(op, cl) < ema33)
      return;

   bool isBear = (cl < op);
   double upperWick, body, lowerWick;

   if(isBear)
   {
      upperWick = hi - op;
      body      = op - cl;
      lowerWick = cl - lo;
      if(upperWick <= body || upperWick <= lowerWick) return;
   }
   else
   {
      upperWick = hi - cl;
      body      = cl - op;
      lowerWick = op - lo;
      if(upperWick <= body || upperWick <= lowerWick) return;
   }

   if(upperWick <= 0) return;

   //--- Hidden SL = candle high + 3 points buffer
   double slLevel = NormalizeDouble(hi + SL_Buffer_Points * _Point, _Digits);

   //--- TP = 5x wick distance below close
   double tp = NormalizeDouble(cl - (TP_Multiplier * upperWick), _Digits);

   //--- Calculate lot using OrderCalcProfit
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot = CalcLotFromRisk(price, slLevel, true);

   if(g_trade.Sell(lot, _Symbol, price, 0, tp,
      StringFormat("EMA%d/%d Sell|Risk$%.0f", EMA_Fast_Period, EMA_Slow_Period, Risk_Amount)))
   {
      ulong ticket = g_trade.ResultOrder();
      AddTrade(ticket, slLevel, 1);
      Print(StringFormat("SELL #%d: Price=%.2f Lot=%.2f SL=%.2f TP=%.2f Risk=$%.2f",
            ticket, price, lot, slLevel, tp, Risk_Amount));
   }
   else
      Print("SELL FAILED: ", g_trade.ResultRetcode(), " - ", g_trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| BUY ENTRY                                                          |
//| Bear candle: (C-L) > (O-C) AND (C-L) > (H-O)                    |
//| Bull candle: (O-L) > (C-O) AND (O-L) > (H-C)                    |
//+------------------------------------------------------------------+
void CheckBuyEntry(double op, double hi, double lo, double cl, double ema33)
{
   if(!IsLowestLow(lo, 1))
      return;

   if(MathMax(op, cl) > ema33)
      return;

   bool isBear = (cl < op);
   double upperWick, body, lowerWick;

   if(isBear)
   {
      lowerWick = cl - lo;
      body      = op - cl;
      upperWick = hi - op;
      if(lowerWick <= body || lowerWick <= upperWick) return;
   }
   else
   {
      lowerWick = op - lo;
      body      = cl - op;
      upperWick = hi - cl;
      if(lowerWick <= body || lowerWick <= upperWick) return;
   }

   if(lowerWick <= 0) return;

   //--- Hidden SL = candle low - 3 points buffer
   double slLevel = NormalizeDouble(lo - SL_Buffer_Points * _Point, _Digits);

   //--- TP = 5x wick distance above close
   double tp = NormalizeDouble(cl + (TP_Multiplier * lowerWick), _Digits);

   //--- Calculate lot using OrderCalcProfit
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double lot = CalcLotFromRisk(price, slLevel, false);

   if(g_trade.Buy(lot, _Symbol, price, 0, tp,
      StringFormat("EMA%d/%d Buy|Risk$%.0f", EMA_Fast_Period, EMA_Slow_Period, Risk_Amount)))
   {
      ulong ticket = g_trade.ResultOrder();
      AddTrade(ticket, slLevel, -1);
      Print(StringFormat("BUY #%d: Price=%.2f Lot=%.2f SL=%.2f TP=%.2f Risk=$%.2f",
            ticket, price, lot, slLevel, tp, Risk_Amount));
   }
   else
      Print("BUY FAILED: ", g_trade.ResultRetcode(), " - ", g_trade.ResultRetcodeDescription());
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
//| Update chart comment                                               |
//+------------------------------------------------------------------+
void UpdateChartComment(double emaFastVal, double emaSlowVal)
{
   string signal = "None";
   if(g_crossDir == 1)  signal = "SELL";
   if(g_crossDir == -1) signal = "BUY";

   string status = "";
   if(g_crossDir != 0 && g_barsSinceCross <= Max_Candles)
      status = StringFormat(" [Scanning %d/%d]", g_barsSinceCross, Max_Candles);
   else if(g_crossDir != 0 && g_barsSinceCross > Max_Candles)
      status = " [Window Expired]";

   string tradingStatus = IsTradingTime() ? "ACTIVE" : "PAUSED";
   if(IsCloseTime()) tradingStatus = "CLOSING";

   string tradeInfo = "";
   if(g_tradeCount > 0)
   {
      tradeInfo = StringFormat("\nActive Trades: %d", g_tradeCount);
      for(int i = 0; i < g_tradeCount && i < 5; i++)
         tradeInfo += StringFormat("\n  #%d SL:%.2f (%s)",
            g_trades[i].ticket, g_trades[i].slLevel,
            g_trades[i].direction == 1 ? "Sell" : "Buy");
   }

   Comment(StringFormat(
      "====== EMA Crossover EA v1.8 ======\n"
      "EMA %d: %.2f  |  EMA %d: %.2f\n"
      "Risk: $%.2f  |  SL Buffer: %.0f pts\n"
      "Signal: %s%s\n"
      "Trading: %s%s\n"
      "===================================",
      EMA_Fast_Period, emaFastVal, EMA_Slow_Period, emaSlowVal,
      Risk_Amount, SL_Buffer_Points,
      signal, status,
      tradingStatus,
      tradeInfo
   ));
}
//+------------------------------------------------------------------+
