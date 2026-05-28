//+------------------------------------------------------------------+
//|                                          EMA_Crossover_EA.mq5     |
//|                                          Copyright 2026            |
//|              EMA 100/200 Trend + RSI(3) Crossover Strategy         |
//+------------------------------------------------------------------+
#property copyright "EMA Crossover EA v2.0"
#property version   "2.00"
#property description "EMA 100/200 Trend + RSI(3) Crossover Entry"
#property description "Designed for Gold (XAUUSD) on M1 timeframe"
#property description "Exit: 2 consecutive candles closing beyond EMA 250"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                   |
//+------------------------------------------------------------------+

input group "══════ EMA Settings ══════"
input int      EMA_Mid_Period    = 100;        // EMA Mid Period (trend filter)
input int      EMA_Slow_Period   = 200;        // EMA Slow Period (trend filter)
input int      EMA_Exit_Period   = 250;        // EMA Exit Period (close condition)
input int      Max_Candles       = 39;         // Max candles after cross for entry

input group "══════ RSI Settings ══════"
input int      RSI_Period        = 3;          // RSI Period
input double   RSI_Buy_Level     = 7.0;        // RSI level for Buy (cross above)
input double   RSI_Sell_Level    = 93.0;       // RSI level for Sell (cross below)

input group "══════ Time Filter (Server Time) ══════"
input int      Market_Open_Hour  = 1;          // Daily Market Open Hour
input int      Market_Open_Min   = 0;          // Daily Market Open Minute
input int      Market_Close_Hour = 23;         // Daily Market Close Hour
input int      Market_Close_Min  = 59;         // Daily Market Close Minute
input int      Open_Delay_Min    = 60;         // Minutes after open to start trading
input int      Close_Before_Min  = 10;         // Minutes before close to exit all trades

input group "══════ Trade Settings ══════"
input double   Lot_Size          = 0.01;       // Lot Size
input double   Take_Profit_Pts   = 0.0;        // Take Profit (points, 0 = disabled)
input int      Magic_Number      = 202601;     // Magic Number
input int      Max_Slippage      = 30;         // Maximum Slippage (points)

//+------------------------------------------------------------------+
//| Trade tracking structure                                           |
//+------------------------------------------------------------------+
struct TradeInfo
{
   ulong  ticket;
   int    direction;   // 1 = sell, -1 = buy
};

//+------------------------------------------------------------------+
//| Global Variables                                                   |
//+------------------------------------------------------------------+

int    g_handleEMAMid;
int    g_handleEMASlow;
int    g_handleEMAExit;
int    g_handleRSI;
CTrade g_trade;

datetime g_lastBarTime    = 0;
int      g_crossDir       = 0;     // 1 = sell signal (100 below 200), -1 = buy signal (100 above 200)
int      g_barsSinceCross = 0;
int      g_prevEMARelation= 0;     // 1 = 100 > 200 (bullish), -1 = 100 < 200 (bearish)

TradeInfo g_trades[];
int       g_tradeCount = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   g_handleEMAMid  = iMA(_Symbol, PERIOD_CURRENT, EMA_Mid_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEMASlow = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEMAExit = iMA(_Symbol, PERIOD_CURRENT, EMA_Exit_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_handleRSI     = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);

   if(g_handleEMAMid == INVALID_HANDLE || g_handleEMASlow == INVALID_HANDLE ||
      g_handleEMAExit == INVALID_HANDLE || g_handleRSI == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicators");
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber(Magic_Number);
   g_trade.SetDeviationInPoints(Max_Slippage);

   double emaMid[2], emaSlow[2];
   if(CopyBuffer(g_handleEMAMid, 0, 1, 2, emaMid) >= 2 &&
      CopyBuffer(g_handleEMASlow, 0, 1, 2, emaSlow) >= 2)
   {
      ArraySetAsSeries(emaMid, true);
      ArraySetAsSeries(emaSlow, true);
      if(emaMid[0] > emaSlow[0])      g_prevEMARelation = 1;
      else if(emaMid[0] < emaSlow[0]) g_prevEMARelation = -1;
   }

   g_tradeCount = 0;
   ArrayResize(g_trades, 0);

   Print("EMA Crossover EA v2.0 initialized | EMA ", EMA_Mid_Period, "/", EMA_Slow_Period,
         "/", EMA_Exit_Period,
         " | RSI(", RSI_Period, ") Buy<", DoubleToString(RSI_Buy_Level, 1),
         " Sell>", DoubleToString(RSI_Sell_Level, 1),
         " | Lot: ", DoubleToString(Lot_Size, 2),
         " | TP: ", (Take_Profit_Pts > 0 ? DoubleToString(Take_Profit_Pts, 1) + " pts" : "OFF"),
         " | Window: ", Max_Candles, " bars",
         " | Magic: ", Magic_Number);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_handleEMAMid  != INVALID_HANDLE) IndicatorRelease(g_handleEMAMid);
   if(g_handleEMASlow != INVALID_HANDLE) IndicatorRelease(g_handleEMASlow);
   if(g_handleEMAExit != INVALID_HANDLE) IndicatorRelease(g_handleEMAExit);
   if(g_handleRSI     != INVALID_HANDLE) IndicatorRelease(g_handleRSI);
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

   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   bool newBar = (barTime != g_lastBarTime);
   if(!newBar) return;
   g_lastBarTime = barTime;

   //--- Get indicator values
   double emaMid[3], emaSlow[3], emaExit[3], rsi[3];
   if(CopyBuffer(g_handleEMAMid,  0, 0, 3, emaMid)  < 3) return;
   if(CopyBuffer(g_handleEMASlow, 0, 0, 3, emaSlow) < 3) return;
   if(CopyBuffer(g_handleEMAExit, 0, 0, 3, emaExit) < 3) return;
   if(CopyBuffer(g_handleRSI,     0, 0, 3, rsi)     < 3) return;
   ArraySetAsSeries(emaMid,  true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(emaExit, true);
   ArraySetAsSeries(rsi,     true);

   //--- Check EMA 250 exit condition on every new bar
   CheckEMA250Exit(emaExit);
   CleanupClosedTrades();

   //--- Detect EMA 100/200 crossover (using bar 1 = last closed bar)
   int currRelation = 0;
   if(emaMid[1] > emaSlow[1])      currRelation = 1;   // 100 above 200 = bullish
   else if(emaMid[1] < emaSlow[1]) currRelation = -1;  // 100 below 200 = bearish

   if(g_prevEMARelation != 0 && currRelation != 0 && g_prevEMARelation != currRelation)
   {
      if(currRelation == 1)
      {
         g_crossDir       = -1;   // EMA100 crossed above EMA200 -> BUY signal
         g_barsSinceCross = 0;
         Print(">>> SIGNAL: EMA", EMA_Mid_Period, " crossed ABOVE EMA", EMA_Slow_Period, " -> BUY");
      }
      else if(currRelation == -1)
      {
         g_crossDir       = 1;    // EMA100 crossed below EMA200 -> SELL signal
         g_barsSinceCross = 0;
         Print(">>> SIGNAL: EMA", EMA_Mid_Period, " crossed BELOW EMA", EMA_Slow_Period, " -> SELL");
      }
   }

   if(currRelation != 0)
      g_prevEMARelation = currRelation;

   UpdateChartComment(emaMid[0], emaSlow[0], emaExit[0], rsi[0]);

   if(g_crossDir != 0)
      g_barsSinceCross++;

   if(g_crossDir == 0)               return;
   if(g_barsSinceCross > Max_Candles) return;
   if(!IsTradingTime())               return;

   //--- Entry candle data (bar 1 = last closed candle)
   double cl     = iClose(_Symbol, PERIOD_CURRENT, 1);
   double ema100 = emaMid[1];
   double ema250 = emaExit[1];

   //--- RSI crossover check: bar 2 = previous RSI, bar 1 = current RSI
   double rsiPrev = rsi[2];
   double rsiCurr = rsi[1];

   if(g_crossDir == -1)  // BUY signal
   {
      // Price must be above EMA 100
      if(cl <= ema100) return;

      // RSI(3) must cross above buy level (was below, now above)
      if(!(rsiPrev <= RSI_Buy_Level && rsiCurr > RSI_Buy_Level)) return;

      ExecuteBuy(cl, ema250);
   }
   else if(g_crossDir == 1)  // SELL signal
   {
      // Price must be below EMA 100
      if(cl >= ema100) return;

      // RSI(3) must cross below sell level (was above, now below)
      if(!(rsiPrev >= RSI_Sell_Level && rsiCurr < RSI_Sell_Level)) return;

      ExecuteSell(cl, ema250);
   }
}

//+------------------------------------------------------------------+
//| Check EMA 250 exit: 2 consecutive candles closing beyond           |
//+------------------------------------------------------------------+
void CheckEMA250Exit(double &emaExit[])
{
   if(g_tradeCount == 0) return;

   double cl1 = iClose(_Symbol, PERIOD_CURRENT, 1);  // last closed bar
   double cl2 = iClose(_Symbol, PERIOD_CURRENT, 2);  // bar before that

   for(int i = g_tradeCount - 1; i >= 0; i--)
   {
      if(g_trades[i].direction == -1)  // BUY: close if 2 candles close below EMA 250
      {
         if(cl2 < emaExit[2] && cl1 < emaExit[1])
         {
            Print(StringFormat("EMA250 EXIT (Buy #%d): 2 candles closed below EMA%d (%.2f, %.2f)",
                  g_trades[i].ticket, EMA_Exit_Period, cl2, cl1));
            g_trade.PositionClose(g_trades[i].ticket);
            RemoveTrade(i);
         }
      }
      else if(g_trades[i].direction == 1)  // SELL: close if 2 candles close above EMA 250
      {
         if(cl2 > emaExit[2] && cl1 > emaExit[1])
         {
            Print(StringFormat("EMA250 EXIT (Sell #%d): 2 candles closed above EMA%d (%.2f, %.2f)",
                  g_trades[i].ticket, EMA_Exit_Period, cl2, cl1));
            g_trade.PositionClose(g_trades[i].ticket);
            RemoveTrade(i);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Execute BUY trade                                                  |
//+------------------------------------------------------------------+
void ExecuteBuy(double entryClose, double ema250)
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double lot = NormalizeLot(Lot_Size);

   double tp = 0;
   if(Take_Profit_Pts > 0)
      tp = NormalizeDouble(price + Take_Profit_Pts * _Point, _Digits);

   if(g_trade.Buy(lot, _Symbol, price, 0, tp,
      StringFormat("EMA%d/%d RSI Buy", EMA_Mid_Period, EMA_Slow_Period)))
   {
      ulong ticket = g_trade.ResultOrder();
      AddTrade(ticket, -1);
      Print(StringFormat("BUY #%d: Price=%.2f Lot=%.2f TP=%.2f",
            ticket, price, lot, tp));
   }
   else
      Print("BUY FAILED: ", g_trade.ResultRetcode(), " - ", g_trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Execute SELL trade                                                 |
//+------------------------------------------------------------------+
void ExecuteSell(double entryClose, double ema250)
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot = NormalizeLot(Lot_Size);

   double tp = 0;
   if(Take_Profit_Pts > 0)
      tp = NormalizeDouble(price - Take_Profit_Pts * _Point, _Digits);

   if(g_trade.Sell(lot, _Symbol, price, 0, tp,
      StringFormat("EMA%d/%d RSI Sell", EMA_Mid_Period, EMA_Slow_Period)))
   {
      ulong ticket = g_trade.ResultOrder();
      AddTrade(ticket, 1);
      Print(StringFormat("SELL #%d: Price=%.2f Lot=%.2f TP=%.2f",
            ticket, price, lot, tp));
   }
   else
      Print("SELL FAILED: ", g_trade.ResultRetcode(), " - ", g_trade.ResultRetcodeDescription());
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
//| Remove trades closed externally                                    |
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
void AddTrade(ulong ticket, int direction)
{
   g_tradeCount++;
   ArrayResize(g_trades, g_tradeCount);
   g_trades[g_tradeCount - 1].ticket    = ticket;
   g_trades[g_tradeCount - 1].direction = direction;
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
void UpdateChartComment(double emaMidVal, double emaSlowVal, double emaExitVal, double rsiVal)
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
         tradeInfo += StringFormat("\n  #%d (%s)",
            g_trades[i].ticket,
            g_trades[i].direction == 1 ? "Sell" : "Buy");
   }

   string tpStr = (Take_Profit_Pts > 0) ? DoubleToString(Take_Profit_Pts, 1) + " pts" : "OFF";

   Comment(StringFormat(
      "====== EMA Crossover EA v2.0 ======\n"
      "EMA %d: %.2f  |  EMA %d: %.2f\n"
      "EMA %d (Exit): %.2f\n"
      "RSI(%d): %.2f  |  Buy<%.1f  Sell>%.1f\n"
      "Lot: %.2f  |  TP: %s\n"
      "Signal: %s%s\n"
      "Trading: %s%s\n"
      "===================================",
      EMA_Mid_Period, emaMidVal, EMA_Slow_Period, emaSlowVal,
      EMA_Exit_Period, emaExitVal,
      RSI_Period, rsiVal, RSI_Buy_Level, RSI_Sell_Level,
      Lot_Size, tpStr,
      signal, status,
      tradingStatus,
      tradeInfo
   ));
}
//+------------------------------------------------------------------+
