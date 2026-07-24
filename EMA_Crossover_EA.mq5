//+------------------------------------------------------------------+
//|                                          EMA_Crossover_EA.mq5     |
//|                                          Copyright 2026            |
//|        EMA 3/9 Cross + Pullback/Reclaim Pattern Entry             |
//+------------------------------------------------------------------+
#property copyright "EMA Crossover EA v4.0"
#property version   "4.00"
#property description "EMA3 crosses EMA9 -> watch the next candles -> pullback then reclaim = entry"
#property description "Forward candle tracker: direction is LOCKED at the cross (a buy cross can only buy)"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                   |
//+------------------------------------------------------------------+

input group "══════ EMA / Pattern Settings ══════"
input int      EMA_Fast_Period   = 3;          // EMA Fast Period (crosses)
input int      EMA_Slow_Period   = 9;          // EMA Slow Period (reference)
input int      Max_Pullback_Candle = 4;        // Latest candle the pullback may be (cross = candle 1, so 2..this)
input bool     Enable_Buy        = true;       // Enable Buy entries
input bool     Enable_Sell       = true;       // Enable Sell entries (mirror of buy)
input bool     Trend_Filter      = false;      // OPTIONAL: buy only if EMA3>EMA9 / sell only if EMA3<EMA9 (off = pure pattern)
input bool     One_Trade_At_A_Time = false;    // If true, skip new entries while a position is open (off = take every valid pattern)
input bool     Verbose_Log       = true;       // Print each step (cross / pullback / entry) to the Experts log
input bool     Draw_Markers      = true;       // Draw pullback (yellow) + entry (blue/red) arrows and value labels

input group "══════ Risk / Trade Settings ══════"
input double   Risk_Percent      = 1.0;        // Risk per trade (% of balance) = SL distance
input int      Magic_Number      = 202601;     // Magic Number
input int      Max_Slippage      = 30;         // Maximum Slippage (points)

input group "══════ Time Filter (Server Time) ══════"
input int      Market_Open_Hour  = 1;          // Daily Market Open Hour
input int      Market_Open_Min   = 0;          // Daily Market Open Minute
input int      Market_Close_Hour = 23;         // Daily Market Close Hour
input int      Market_Close_Min  = 59;         // Daily Market Close Minute
input int      Open_Delay_Min    = 60;         // Minutes after open to start trading
input int      Close_Before_Min  = 10;         // Minutes before close to stop NEW entries
input bool     Close_At_Market_End = false;    // Force-close open trades before market close

//+------------------------------------------------------------------+
//| Trade tracking structure                                           |
//+------------------------------------------------------------------+
struct TradeInfo
{
   ulong  ticket;
   int    direction;   // 1 = sell, -1 = buy
   double slLevel;     // candle-close stop level (2-candle low for buy / high for sell)
};

//+------------------------------------------------------------------+
//| Global Variables                                                   |
//+------------------------------------------------------------------+
int    g_handleEMAFast;
int    g_handleEMASlow;
CTrade g_trade;

datetime g_lastBarTime = 0;

TradeInfo g_trades[];
int       g_tradeCount = 0;

//--- Setup tracker (the forward candle watcher after a cross) ---
int      g_setupDir      = 0;   // 0 = idle (waiting for a cross), +1 = watching for BUY, -1 = watching for SELL
int      g_barsSinceCross = 0;  // the cross candle itself is candle 1; each new candle adds 1
bool     g_pullbackDone  = false;
int      g_pbCandNo      = 0;   // which candle number the pullback landed on
double   g_pbLow = 0, g_pbHigh = 0, g_pbOpen = 0, g_pbClose = 0, g_pbE9 = 0;
datetime g_pbTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   g_handleEMAFast = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEMASlow = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);

   if(g_handleEMAFast == INVALID_HANDLE || g_handleEMASlow == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicators");
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber(Magic_Number);
   g_trade.SetDeviationInPoints(Max_Slippage);

   g_tradeCount = 0;
   ArrayResize(g_trades, 0);
   ResetSetup();

   Print("EMA Crossover EA v4.0 initialized | EMA ", EMA_Fast_Period, "/", EMA_Slow_Period,
         " | Pullback allowed candles 2-", Max_Pullback_Candle,
         " | Risk: ", DoubleToString(Risk_Percent, 2), "%",
         " | Buy: ", (Enable_Buy ? "ON" : "OFF"),
         " | Sell: ", (Enable_Sell ? "ON" : "OFF"),
         " | Magic: ", Magic_Number);

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
//| Expert tick function - runs once per new closed candle            |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Optional: force-close trades before market close (OFF by default)
   if(Close_At_Market_End && IsCloseTime())
   {
      CloseAllTrades();
      g_tradeCount = 0;
      ArrayResize(g_trades, 0);
      return;
   }

   //--- Act only once per new bar (on the just-closed candle)
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(barTime == g_lastBarTime) return;
   g_lastBarTime = barTime;

   //--- Manage open trades (candle-close stop)
   ManageOpenTrades();
   CleanupClosedTrades();

   //--- EMA values: bar 1 = last closed candle, bar 2 = the one before it
   double ema3[], ema9[];
   ArraySetAsSeries(ema3, true);
   ArraySetAsSeries(ema9, true);
   if(CopyBuffer(g_handleEMAFast, 0, 0, 3, ema3) < 3) return;
   if(CopyBuffer(g_handleEMASlow, 0, 0, 3, ema9) < 3) return;

   //--- The just-closed candle (bar 1)
   double o1 = iOpen(_Symbol,  PERIOD_CURRENT, 1);
   double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double h1 = iHigh(_Symbol,  PERIOD_CURRENT, 1);
   double l1 = iLow(_Symbol,   PERIOD_CURRENT, 1);

   //--- STATE 1: idle -> look for a fresh EMA3/EMA9 cross on this candle
   if(g_setupDir == 0)
      DetectCross(ema3, ema9);
   //--- STATE 2: a cross already happened -> watch the following candles for pullback then reclaim
   else
      AdvanceSetup(ema3, ema9, o1, c1, h1, l1);

   UpdateChartComment(ema3[1], ema9[1]);
}

//+------------------------------------------------------------------+
//| STATE 1 - detect the cross and LOCK the direction                 |
//|  A bullish cross can only ever become a BUY. A bearish cross only  |
//|  a SELL. Once locked, EMA re-crosses (from the pullback) are       |
//|  ignored until the setup completes or the window runs out.         |
//+------------------------------------------------------------------+
void DetectCross(const double &ema3[], const double &ema9[])
{
   bool crossUp   = (ema3[1] > ema9[1] && ema3[2] <= ema9[2]);   // EMA3 crossed ABOVE EMA9
   bool crossDown = (ema3[1] < ema9[1] && ema3[2] >= ema9[2]);   // EMA3 crossed BELOW EMA9

   if(crossUp && Enable_Buy)
   {
      g_setupDir       = +1;   // watching for a BUY
      g_barsSinceCross = 1;    // the cross candle is candle 1
      g_pullbackDone   = false;
      if(Verbose_Log) Print("Bullish cross (EMA3 above EMA9) -> watching candles 2-", Max_Pullback_Candle, " for a BUY pullback");
   }
   else if(crossDown && Enable_Sell)
   {
      g_setupDir       = -1;   // watching for a SELL
      g_barsSinceCross = 1;
      g_pullbackDone   = false;
      if(Verbose_Log) Print("Bearish cross (EMA3 below EMA9) -> watching candles 2-", Max_Pullback_Candle, " for a SELL pullback");
   }
}

//+------------------------------------------------------------------+
//| STATE 2 - walk the candles after the cross                        |
//|  candle 2..Max_Pullback_Candle : look for the pullback            |
//|  the candle right after the pullback : must reclaim = entry        |
//|  direction is fixed by the cross, never re-derived here            |
//+------------------------------------------------------------------+
void AdvanceSetup(const double &ema3[], const double &ema9[],
                  double o1, double c1, double h1, double l1)
{
   g_barsSinceCross++;             // this just-closed candle is candle g_barsSinceCross
   double e9 = ema9[1];
   int    dir = g_setupDir;

   // What this candle looks like relative to EMA9
   bool isPullback = (dir == +1) ? (o1 > e9 && c1 < e9)    // BUY  pullback: opens ABOVE, closes BELOW (bearish through EMA9)
                                 : (o1 < e9 && c1 > e9);    // SELL pullback: opens BELOW, closes ABOVE (bullish through EMA9)
   bool isReclaim  = (dir == +1) ? (o1 < e9 && c1 > e9)    // BUY  reclaim : opens BELOW, closes ABOVE
                                 : (o1 > e9 && c1 < e9);    // SELL reclaim : opens ABOVE, closes BELOW

   // --- If we already have a pullback, THIS candle must be the reclaim ---
   if(g_pullbackDone)
   {
      if(isReclaim)
      {
         if(Trend_Filter &&
            ((dir == +1 && !(ema3[1] > ema9[1])) || (dir == -1 && !(ema3[1] < ema9[1]))))
         {
            if(Verbose_Log) Print((dir==+1?"BUY":"SELL"), " skipped by trend filter");
            ResetSetup();
            return;
         }
         EnterTrade(dir, o1, c1, h1, l1, ema3[1], ema9[1]);
         ResetSetup();
         return;
      }
      // Reclaim didn't come on the very next candle -> drop this pullback.
      // (This same candle may itself start a fresh pullback below.)
      g_pullbackDone = false;
   }

   // --- Looking for the pullback (allowed on candles 2..Max_Pullback_Candle) ---
   if(!g_pullbackDone && isPullback && g_barsSinceCross <= Max_Pullback_Candle)
   {
      g_pullbackDone = true;
      g_pbCandNo = g_barsSinceCross;
      g_pbLow = l1;  g_pbHigh = h1;
      g_pbOpen = o1; g_pbClose = c1; g_pbE9 = e9;
      g_pbTime = iTime(_Symbol, PERIOD_CURRENT, 1);

      if(Verbose_Log)
         Print((dir==+1?"BUY":"SELL"), " pullback found on candle ", g_pbCandNo,
               " | O=", DoubleToString(o1,2), " C=", DoubleToString(c1,2), " E9=", DoubleToString(e9,2),
               " -> next candle must reclaim");

      if(Draw_Markers)
      {
         if(dir == +1) DrawArrow(g_pbTime, h1, OBJ_ARROW_DOWN, clrYellow);
         else          DrawArrow(g_pbTime, l1, OBJ_ARROW_UP,   clrYellow);
      }
   }

   // --- Window ran out with no pullback -> give up and wait for the next cross ---
   if(!g_pullbackDone && g_barsSinceCross >= Max_Pullback_Candle)
   {
      if(Verbose_Log) Print("No pullback by candle ", Max_Pullback_Candle, " -> reset, waiting for next cross");
      ResetSetup();
   }
}

//+------------------------------------------------------------------+
//| Reset the setup tracker back to idle                              |
//+------------------------------------------------------------------+
void ResetSetup()
{
   g_setupDir       = 0;
   g_barsSinceCross = 0;
   g_pullbackDone   = false;
   g_pbCandNo       = 0;
}

//+------------------------------------------------------------------+
//| Enter the trade on the reclaim candle                             |
//|  dir: +1 = buy, -1 = sell   (bar 1 = the reclaim candle)          |
//+------------------------------------------------------------------+
void EnterTrade(int dir, double o1, double c1, double h1, double l1, double ema3v, double ema9v)
{
   if(One_Trade_At_A_Time && HasOpenPosition()) { ResetSetup(); return; }
   if(!IsTradingTime()) return;

   int enCand = g_barsSinceCross;   // entry candle number (cross = candle 1)
   int pbCand = g_pbCandNo;
   datetime enTime = iTime(_Symbol, PERIOD_CURRENT, 1);

   if(dir == +1)
   {
      double sl   = MathMin(g_pbLow, l1);   // lowest low of pullback + entry candles
      double risk = c1 - sl;
      if(risk <= 0) return;
      double tp   = c1 + risk;              // 1:1

      if(Verbose_Log)
         Print(StringFormat("BUY ENTRY: cross=cand1 PB=cand%d EN=cand%d | PB O=%.2f C=%.2f E9=%.2f | EN O=%.2f C=%.2f E9=%.2f",
               pbCand, enCand, g_pbOpen, g_pbClose, g_pbE9, o1, c1, ema9v));

      if(Draw_Markers)
      {
         DrawArrow(enTime, l1, OBJ_ARROW_UP, clrDodgerBlue);
         DrawLabel(enTime, l1,
            StringFormat("cross=cand1 PB=cand%d EN=cand%d | PB O%.2f C%.2f E9=%.2f | EN O%.2f C%.2f E9=%.2f | EMA3=%.2f",
               pbCand, enCand, g_pbOpen, g_pbClose, g_pbE9, o1, c1, ema9v, ema3v), clrWhite);
      }
      ExecuteBuy(sl, tp, risk);
   }
   else
   {
      double sl   = MathMax(g_pbHigh, h1);  // highest high of pullback + entry candles
      double risk = sl - c1;
      if(risk <= 0) return;
      double tp   = c1 - risk;

      if(Verbose_Log)
         Print(StringFormat("SELL ENTRY: cross=cand1 PB=cand%d EN=cand%d | PB O=%.2f C=%.2f E9=%.2f | EN O=%.2f C=%.2f E9=%.2f",
               pbCand, enCand, g_pbOpen, g_pbClose, g_pbE9, o1, c1, ema9v));

      if(Draw_Markers)
      {
         DrawArrow(enTime, h1, OBJ_ARROW_DOWN, clrRed);
         DrawLabel(enTime, h1,
            StringFormat("cross=cand1 PB=cand%d EN=cand%d | PB O%.2f C%.2f E9=%.2f | EN O%.2f C%.2f E9=%.2f | EMA3=%.2f",
               pbCand, enCand, g_pbOpen, g_pbClose, g_pbE9, o1, c1, ema9v, ema3v), clrWhite);
      }
      ExecuteSell(sl, tp, risk);
   }
}

//+------------------------------------------------------------------+
//| Is there already an open position from this EA?                    |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 &&
         PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == Magic_Number)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Draw a marker arrow on a specific candle                           |
//+------------------------------------------------------------------+
void DrawArrow(datetime t, double price, ENUM_OBJECT type, color clr)
{
   string name = "EMA_mk_" + IntegerToString((long)t) + "_" + IntegerToString((int)type);
   if(ObjectFind(0, name) >= 0) return;
   if(!ObjectCreate(0, name, type, 0, t, price)) return;
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| Draw a small text label (shows the exact O/C/EMA9 the EA used)    |
//+------------------------------------------------------------------+
void DrawLabel(datetime t, double price, string text, color clr)
{
   string name = "EMA_lbl_" + IntegerToString((long)t);
   if(ObjectFind(0, name) >= 0) return;
   if(!ObjectCreate(0, name, OBJ_TEXT, 0, t, price)) return;
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 7);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| Execute BUY trade                                                  |
//+------------------------------------------------------------------+
void ExecuteBuy(double slLevel, double tpLevel, double riskDist)
{
   double lot = CalcLotByRisk(riskDist);
   if(lot <= 0)
   {
      Print("BUY skipped: could not size lot (risk distance ", DoubleToString(riskDist, _Digits), ")");
      return;
   }

   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double tp    = NormalizeDouble(tpLevel, _Digits);

   if(g_trade.Buy(lot, _Symbol, price, 0, tp, "EMA3/9 Reclaim Buy"))
   {
      ulong ticket = g_trade.ResultOrder();
      AddTrade(ticket, -1, slLevel);
      Print(StringFormat("BUY #%d: Price=%.2f Lot=%.2f SLclose=%.2f TP=%.2f RiskDist=%.2f",
            ticket, price, lot, slLevel, tp, riskDist));
   }
   else
      Print("BUY FAILED: ", g_trade.ResultRetcode(), " - ", g_trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Execute SELL trade                                                 |
//+------------------------------------------------------------------+
void ExecuteSell(double slLevel, double tpLevel, double riskDist)
{
   double lot = CalcLotByRisk(riskDist);
   if(lot <= 0)
   {
      Print("SELL skipped: could not size lot (risk distance ", DoubleToString(riskDist, _Digits), ")");
      return;
   }

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tp    = NormalizeDouble(tpLevel, _Digits);

   if(g_trade.Sell(lot, _Symbol, price, 0, tp, "EMA3/9 Reclaim Sell"))
   {
      ulong ticket = g_trade.ResultOrder();
      AddTrade(ticket, 1, slLevel);
      Print(StringFormat("SELL #%d: Price=%.2f Lot=%.2f SLclose=%.2f TP=%.2f RiskDist=%.2f",
            ticket, price, lot, slLevel, tp, riskDist));
   }
   else
      Print("SELL FAILED: ", g_trade.ResultRetcode(), " - ", g_trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Candle-close stop: close trade when a candle closes beyond level  |
//+------------------------------------------------------------------+
void ManageOpenTrades()
{
   if(g_tradeCount == 0) return;

   double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);  // last closed candle

   for(int i = g_tradeCount - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(g_trades[i].ticket))
      {
         RemoveTrade(i);
         continue;
      }

      if(g_trades[i].direction == -1)  // BUY: close if candle closes below SL level
      {
         if(c1 < g_trades[i].slLevel)
         {
            Print(StringFormat("SL EXIT (Buy #%d): candle closed %.2f below level %.2f",
                  g_trades[i].ticket, c1, g_trades[i].slLevel));
            g_trade.PositionClose(g_trades[i].ticket);
            RemoveTrade(i);
         }
      }
      else if(g_trades[i].direction == 1)  // SELL: close if candle closes above SL level
      {
         if(c1 > g_trades[i].slLevel)
         {
            Print(StringFormat("SL EXIT (Sell #%d): candle closed %.2f above level %.2f",
                  g_trades[i].ticket, c1, g_trades[i].slLevel));
            g_trade.PositionClose(g_trades[i].ticket);
            RemoveTrade(i);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Percentage-risk lot sizing (risk = SL distance)                   |
//+------------------------------------------------------------------+
double CalcLotByRisk(double riskDistancePrice)
{
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * Risk_Percent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize <= 0 || tickValue <= 0 || riskDistancePrice <= 0 || riskMoney <= 0)
      return 0;

   double lossPerLot = (riskDistancePrice / tickSize) * tickValue;
   if(lossPerLot <= 0) return 0;

   double lot = riskMoney / lossPerLot;
   return NormalizeLot(lot);
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
//| Remove trades closed externally (TP hit, manual close)             |
//+------------------------------------------------------------------+
void CleanupClosedTrades()
{
   for(int i = g_tradeCount - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(g_trades[i].ticket))
         RemoveTrade(i);
   }
}

//+------------------------------------------------------------------+
//| Add trade to tracking array                                        |
//+------------------------------------------------------------------+
void AddTrade(ulong ticket, int direction, double slLevel)
{
   g_tradeCount++;
   ArrayResize(g_trades, g_tradeCount);
   g_trades[g_tradeCount - 1].ticket    = ticket;
   g_trades[g_tradeCount - 1].direction = direction;
   g_trades[g_tradeCount - 1].slLevel   = slLevel;
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
   string align = (emaFastVal > emaSlowVal) ? "EMA3 above EMA9 (bullish)"
                : (emaFastVal < emaSlowVal) ? "EMA3 below EMA9 (bearish)"
                : "EMA3 = EMA9";

   string tradingStatus = IsTradingTime() ? "ACTIVE" : "PAUSED";

   string setup;
   if(g_setupDir == 0)
      setup = "Setup: idle - waiting for an EMA3/EMA9 cross";
   else
      setup = StringFormat("Setup: %s | candle %d since cross | pullback %s",
                 (g_setupDir == +1 ? "BUY watch" : "SELL watch"),
                 g_barsSinceCross,
                 (g_pullbackDone ? StringFormat("found on cand%d - next candle must reclaim", g_pbCandNo)
                                 : "not yet"));

   string tradeInfo = "";
   if(g_tradeCount > 0)
   {
      tradeInfo = StringFormat("\nActive Trades: %d", g_tradeCount);
      for(int i = 0; i < g_tradeCount && i < 5; i++)
         tradeInfo += StringFormat("\n  #%d (%s) SL@%.2f",
            g_trades[i].ticket,
            g_trades[i].direction == 1 ? "Sell" : "Buy",
            g_trades[i].slLevel);
   }

   Comment(StringFormat(
      "====== EMA Crossover EA v4.0 ======\n"
      "EMA %d: %.2f  |  EMA %d: %.2f  (%s)\n"
      "Risk: %.2f%%  |  Buy:%s  Sell:%s  Trend filter:%s\n"
      "Pullback allowed: candle 2 to %d (cross = candle 1)\n"
      "%s\n"
      "Trading: %s%s\n"
      "===================================",
      EMA_Fast_Period, emaFastVal, EMA_Slow_Period, emaSlowVal, align,
      Risk_Percent, (Enable_Buy ? "on" : "off"), (Enable_Sell ? "on" : "off"),
      (Trend_Filter ? "on" : "off"),
      Max_Pullback_Candle,
      setup,
      tradingStatus, tradeInfo
   ));
}
//+------------------------------------------------------------------+
