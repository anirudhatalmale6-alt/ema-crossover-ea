//+------------------------------------------------------------------+
//|                                          EMA_Crossover_EA.mq5     |
//|                                          Copyright 2026            |
//|        EMA 3/9 Cross + Pullback/Reclaim Pattern Entry             |
//+------------------------------------------------------------------+
#property copyright "EMA Crossover EA v3.5"
#property version   "3.50"
#property description "EMA3 crosses EMA9, pullback candle through EMA9, reclaim candle = entry"
#property description "Candle-close SL at 2-candle low/high, 1:1 TP, percentage-risk sizing"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                   |
//+------------------------------------------------------------------+

input group "══════ EMA / Pattern Settings ══════"
input int      EMA_Fast_Period   = 3;          // EMA Fast Period (crosses)
input int      EMA_Slow_Period   = 9;          // EMA Slow Period (reference)
input int      Search_Start      = 1;          // First candle after cross to look for pullback (1 = candle right after cross)
input int      Search_Window     = 3;          // Whole pattern (pullback+entry) must finish within this many candles after the cross
input bool     Enable_Buy        = true;       // Enable Buy setups
input bool     Enable_Sell       = true;       // Enable Sell setups (mirror of buy)
input bool     Trend_Filter      = true;       // Buy only while EMA3>EMA9, sell only while EMA3<EMA9 (stops back-to-front entries)
input bool     Verbose_Log       = true;       // Print each pullback/reclaim check to Experts log
input bool     Draw_Markers      = true;       // Draw pullback (yellow) and entry (blue/red) arrows on chart

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

datetime g_lastBarTime  = 0;

// Setup state machine
int    g_pendingDir     = 0;   // 1 = buy setup active, -1 = sell setup active, 0 = idle
int    g_phase          = 0;   // 0 = idle, 1 = searching for pullback candle A, 2 = waiting for reclaim candle B
int    g_barsInSearch   = 0;   // candles counted while searching for candle A
double g_candleA_low    = 0.0; // low of pullback candle (buy)
double g_candleA_high   = 0.0; // high of pullback candle (sell)
double g_pbOpen         = 0.0; // pullback candle open  (for on-chart verification label)
double g_pbClose        = 0.0; // pullback candle close (for on-chart verification label)
double g_pbEma9         = 0.0; // EMA9 at pullback candle (for on-chart verification label)
int    g_pbBar          = 0;   // which candle after the cross the pullback was (1 = first after cross)

TradeInfo g_trades[];
int       g_tradeCount = 0;

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

   g_pendingDir  = 0;
   g_phase       = 0;
   g_tradeCount  = 0;
   ArrayResize(g_trades, 0);

   Print("EMA Crossover EA v3.5 initialized | EMA ", EMA_Fast_Period, "/", EMA_Slow_Period,
         " | Search window: ", Search_Start, "-", Search_Window, " candles",
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
//| Expert tick function                                               |
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

   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   bool newBar = (barTime != g_lastBarTime);
   if(!newBar) return;
   g_lastBarTime = barTime;

   //--- Get indicator values (bar 1 = last closed candle)
   double emaFast[3], emaSlow[3];
   if(CopyBuffer(g_handleEMAFast, 0, 0, 3, emaFast) < 3) return;
   if(CopyBuffer(g_handleEMASlow, 0, 0, 3, emaSlow) < 3) return;
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);

   //--- Manage open trades (candle-close stop)
   ManageOpenTrades();
   CleanupClosedTrades();

   //--- Last closed candle OHLC
   double o1 = iOpen(_Symbol,  PERIOD_CURRENT, 1);
   double h1 = iHigh(_Symbol,  PERIOD_CURRENT, 1);
   double l1 = iLow(_Symbol,   PERIOD_CURRENT, 1);
   double c1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double ema9 = emaSlow[1];

   //--- Detect EMA3/EMA9 cross on the just-closed candle
   bool crossUp = (emaFast[2] <= emaSlow[2] && emaFast[1] >  emaSlow[1]);
   bool crossDn = (emaFast[2] >= emaSlow[2] && emaFast[1] <  emaSlow[1]);

   //--- Only look for a NEW cross when idle. Once a setup is active we must
   //    IGNORE re-crosses, because the pullback candle (which pushes price back
   //    through EMA9) naturally makes the fast EMA re-cross - and that must NOT
   //    flip or restart the setup, or the entry direction gets corrupted.
   bool freshCross = false;
   if(g_pendingDir == 0)
   {
      if(crossUp && Enable_Buy)
      {
         g_pendingDir   = 1;
         g_phase        = 1;
         g_barsInSearch = 0;
         freshCross     = true;
         Print(">>> EMA", EMA_Fast_Period, " crossed ABOVE EMA", EMA_Slow_Period, " -> looking for BUY pullback");
      }
      else if(crossDn && Enable_Sell)
      {
         g_pendingDir   = -1;
         g_phase        = 1;
         g_barsInSearch = 0;
         freshCross     = true;
         Print(">>> EMA", EMA_Fast_Period, " crossed BELOW EMA", EMA_Slow_Period, " -> looking for SELL pullback");
      }
   }

   //--- Evaluate the pattern (skip the cross candle itself)
   if(!freshCross && g_pendingDir != 0)
      EvaluatePattern(o1, h1, l1, c1, ema9, emaFast[1]);

   UpdateChartComment(emaFast[1], emaSlow[1]);
}

//+------------------------------------------------------------------+
//| Walk the pullback -> reclaim state machine                        |
//+------------------------------------------------------------------+
void EvaluatePattern(double o1, double h1, double l1, double c1, double ema9, double emaFastVal)
{
   if(!IsTradingTime())
   {
      // still advance the search window so a stale setup expires naturally
   }

   //================= BUY SETUP =================
   if(g_pendingDir == 1)
   {
      g_barsInSearch++;   // candles since cross (1 = first candle after the cross)

      bool isPullback = (c1 < o1 && o1 > ema9 && c1 < ema9);  // bearish, opens above EMA9, closes below
      bool isReclaim  = (o1 < ema9 && c1 > ema9);             // opens below EMA9, closes above

      // 1) If a pullback is already pending, THIS candle is its reclaim attempt
      if(g_phase == 2)
      {
         bool trendOK = (!Trend_Filter || emaFastVal > ema9);  // buy only with EMA3 above EMA9
         if(isReclaim && trendOK)
         {
            if(Verbose_Log)
               Print(StringFormat("BUY ENTRY | pullback[O=%.2f C=%.2f EMA9=%.2f] entry[O=%.2f C=%.2f EMA9=%.2f] EMA3=%.2f (EMA3>EMA9=%s)",
                  g_pbOpen, g_pbClose, g_pbEma9, o1, c1, ema9, emaFastVal, (emaFastVal>ema9?"Y":"N")));
            if(Draw_Markers)
            {
               DrawArrow(iTime(_Symbol, PERIOD_CURRENT, 1), l1, OBJ_ARROW_UP, clrDodgerBlue); // buy entry candle
               DrawLabel(iTime(_Symbol, PERIOD_CURRENT, 1), l1,
                  StringFormat("cross+%d/%d | PB O%.2f C%.2f E9=%.2f | EN O%.2f C%.2f E9=%.2f | EMA3=%.2f",
                     g_pbBar, g_barsInSearch, g_pbOpen, g_pbClose, g_pbEma9, o1, c1, ema9, emaFastVal), clrWhite);
            }
            double slLevel  = MathMin(g_candleA_low, l1);  // lowest low of the two candles
            double riskDist = c1 - slLevel;                // reclaim close - lowest low
            double tp       = c1 + riskDist;               // 1:1 reward
            if(riskDist > 0 && IsTradingTime())
               ExecuteBuy(slLevel, tp, riskDist);
            else if(Verbose_Log)
               Print(StringFormat("BUY entry blocked: riskDist=%.2f tradingTime=%s", riskDist, (IsTradingTime()?"Y":"N")));
            ResetSetup();
            return;
         }
         // Reclaim failed (wrong shape or counter-trend) -> go back to searching,
         // so a pullback on a LATER candle within the window is not ignored.
         if(Verbose_Log)
            Print(StringFormat("BUY reclaim not taken (isReclaim=%s trendOK=%s) -> keep searching within window",
               (isReclaim?"Y":"N"), (trendOK?"Y":"N")));
         g_phase = 1;
      }

      // 2) Look for a (new) pullback candle - must leave room for the entry inside the window
      if(g_phase == 1 && g_barsInSearch >= Search_Start && g_barsInSearch < Search_Window && isPullback)
      {
         g_candleA_low = l1;
         g_pbOpen = o1;  g_pbClose = c1;  g_pbEma9 = ema9;  g_pbBar = g_barsInSearch;
         g_phase = 2;
         if(Verbose_Log)
            Print(StringFormat("BUY pullback MATCH cand %d: O=%.2f C=%.2f EMA9=%.2f (open>EMA9 & close<EMA9) -> wait reclaim",
               g_barsInSearch, o1, c1, ema9));
         if(Draw_Markers)
            DrawArrow(iTime(_Symbol, PERIOD_CURRENT, 1), h1, OBJ_ARROW_DOWN, clrYellow); // pullback candle
      }

      // 3) Expire once the window is used up and we are not holding a pullback awaiting its reclaim
      if(g_phase == 1 && g_barsInSearch >= Search_Window)
      {
         if(Verbose_Log) Print("BUY setup expired: no pullback/reclaim within window");
         ResetSetup();
      }
   }
   //================= SELL SETUP (mirror) =================
   else if(g_pendingDir == -1)
   {
      g_barsInSearch++;   // candles since cross (1 = first candle after the cross)

      bool isPullback = (c1 > o1 && o1 < ema9 && c1 > ema9);  // bullish, opens below EMA9, closes above
      bool isReclaim  = (o1 > ema9 && c1 < ema9);             // opens above EMA9, closes below

      // 1) If a pullback is already pending, THIS candle is its reclaim attempt
      if(g_phase == 2)
      {
         bool trendOK = (!Trend_Filter || emaFastVal < ema9);  // sell only with EMA3 below EMA9
         if(isReclaim && trendOK)
         {
            if(Verbose_Log)
               Print(StringFormat("SELL ENTRY | pullback[O=%.2f C=%.2f EMA9=%.2f] entry[O=%.2f C=%.2f EMA9=%.2f] EMA3=%.2f (EMA3<EMA9=%s)",
                  g_pbOpen, g_pbClose, g_pbEma9, o1, c1, ema9, emaFastVal, (emaFastVal<ema9?"Y":"N")));
            if(Draw_Markers)
            {
               DrawArrow(iTime(_Symbol, PERIOD_CURRENT, 1), h1, OBJ_ARROW_DOWN, clrRed); // sell entry candle
               DrawLabel(iTime(_Symbol, PERIOD_CURRENT, 1), h1,
                  StringFormat("cross+%d/%d | PB O%.2f C%.2f E9=%.2f | EN O%.2f C%.2f E9=%.2f | EMA3=%.2f",
                     g_pbBar, g_barsInSearch, g_pbOpen, g_pbClose, g_pbEma9, o1, c1, ema9, emaFastVal), clrWhite);
            }
            double slLevel  = MathMax(g_candleA_high, h1); // highest high of the two candles
            double riskDist = slLevel - c1;                // highest high - reclaim close
            double tp       = c1 - riskDist;               // 1:1 reward
            if(riskDist > 0 && IsTradingTime())
               ExecuteSell(slLevel, tp, riskDist);
            else if(Verbose_Log)
               Print(StringFormat("SELL entry blocked: riskDist=%.2f tradingTime=%s", riskDist, (IsTradingTime()?"Y":"N")));
            ResetSetup();
            return;
         }
         // Reclaim failed (wrong shape or counter-trend) -> go back to searching
         if(Verbose_Log)
            Print(StringFormat("SELL reclaim not taken (isReclaim=%s trendOK=%s) -> keep searching within window",
               (isReclaim?"Y":"N"), (trendOK?"Y":"N")));
         g_phase = 1;
      }

      // 2) Look for a (new) pullback candle - must leave room for the entry inside the window
      if(g_phase == 1 && g_barsInSearch >= Search_Start && g_barsInSearch < Search_Window && isPullback)
      {
         g_candleA_high = h1;
         g_pbOpen = o1;  g_pbClose = c1;  g_pbEma9 = ema9;  g_pbBar = g_barsInSearch;
         g_phase = 2;
         if(Verbose_Log)
            Print(StringFormat("SELL pullback MATCH cand %d: O=%.2f C=%.2f EMA9=%.2f (open<EMA9 & close>EMA9) -> wait reclaim",
               g_barsInSearch, o1, c1, ema9));
         if(Draw_Markers)
            DrawArrow(iTime(_Symbol, PERIOD_CURRENT, 1), l1, OBJ_ARROW_UP, clrYellow); // pullback candle
      }

      // 3) Expire once the window is used up and we are not holding a pullback awaiting its reclaim
      if(g_phase == 1 && g_barsInSearch >= Search_Window)
      {
         if(Verbose_Log) Print("SELL setup expired: no pullback/reclaim within window");
         ResetSetup();
      }
   }
}

//+------------------------------------------------------------------+
//| Draw a marker arrow on a specific candle (for visual debugging)   |
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
//| Reset the setup state machine                                     |
//+------------------------------------------------------------------+
void ResetSetup()
{
   g_pendingDir   = 0;
   g_phase        = 0;
   g_barsInSearch = 0;
   g_candleA_low  = 0.0;
   g_candleA_high = 0.0;
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

   // TP as hard order level (broker closes when reached); SL handled on candle close by EA
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
      // verify position still exists
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
   string setup = "Idle (waiting for EMA cross)";
   if(g_pendingDir == 1)
      setup = (g_phase == 1)
              ? StringFormat("BUY: searching pullback %d (window %d-%d)", g_barsInSearch, Search_Start, Search_Window)
              : "BUY: waiting for reclaim candle";
   else if(g_pendingDir == -1)
      setup = (g_phase == 1)
              ? StringFormat("SELL: searching pullback %d (window %d-%d)", g_barsInSearch, Search_Start, Search_Window)
              : "SELL: waiting for reclaim candle";

   string tradingStatus = IsTradingTime() ? "ACTIVE" : "PAUSED";

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
      "====== EMA Crossover EA v3.5 ======\n"
      "EMA %d: %.2f  |  EMA %d: %.2f\n"
      "Risk: %.2f%%  |  Buy:%s  Sell:%s  Trend filter:%s\n"
      "Setup: %s\n"
      "Trading: %s%s\n"
      "===================================",
      EMA_Fast_Period, emaFastVal, EMA_Slow_Period, emaSlowVal,
      Risk_Percent, (Enable_Buy ? "on" : "off"), (Enable_Sell ? "on" : "off"),
      (Trend_Filter ? "on" : "off"),
      setup,
      tradingStatus, tradeInfo
   ));
}
//+------------------------------------------------------------------+
