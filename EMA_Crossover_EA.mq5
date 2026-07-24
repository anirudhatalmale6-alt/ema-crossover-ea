//+------------------------------------------------------------------+
//|                                          EMA_Crossover_EA.mq5     |
//|                                          Copyright 2026            |
//|        EMA 3/9 Cross + Pullback/Reclaim Pattern Entry             |
//+------------------------------------------------------------------+
#property copyright "EMA Crossover EA v3.9"
#property version   "3.90"
#property description "EMA3 crosses EMA9, pullback candle through EMA9, reclaim candle = entry"
#property description "Simple stateless if-checks: read straight off the last few candles"

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
input bool     Verbose_Log       = true;       // Print each entry decision to the Experts log
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

   Print("EMA Crossover EA v3.9 initialized | EMA ", EMA_Fast_Period, "/", EMA_Slow_Period,
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

   //--- How many EMA values we need: cross may be up to (Max_Pullback_Candle+1) bars back, +1 for the pre-cross bar
   int need = Max_Pullback_Candle + 3;
   double ema3[], ema9[];
   ArraySetAsSeries(ema3, true);
   ArraySetAsSeries(ema9, true);
   if(CopyBuffer(g_handleEMAFast, 0, 0, need, ema3) < need) return;
   if(CopyBuffer(g_handleEMASlow, 0, 0, need, ema9) < need) return;

   //--- Try the two patterns straight off the candles (bar 1 = last closed candle)
   CheckBuy(ema3, ema9);
   CheckSell(ema3, ema9);

   UpdateChartComment(ema3[1], ema9[1]);
}

//+------------------------------------------------------------------+
//| BUY pattern - all read directly from the last few candles         |
//|  bar 1 = entry candle, bar 2 = pullback candle, cross a bit back  |
//+------------------------------------------------------------------+
void CheckBuy(const double &ema3[], const double &ema9[])
{
   if(!Enable_Buy) return;
   if(One_Trade_At_A_Time && HasOpenPosition()) return;

   double o1 = iOpen(_Symbol, PERIOD_CURRENT, 1);   // entry candle
   double l1 = iLow(_Symbol,  PERIOD_CURRENT, 1);
   double c1 = iClose(_Symbol,PERIOD_CURRENT, 1);
   double o2 = iOpen(_Symbol, PERIOD_CURRENT, 2);   // pullback candle
   double l2 = iLow(_Symbol,  PERIOD_CURRENT, 2);
   double c2 = iClose(_Symbol,PERIOD_CURRENT, 2);

   // 1) Entry candle = bullish reclaim: opens below EMA9, closes above EMA9
   bool reclaim = (o1 < ema9[1] && c1 > ema9[1]);

   // 2) Pullback candle = bearish: opens above EMA9, closes below EMA9
   bool pullback = (c2 < o2 && o2 > ema9[2] && c2 < ema9[2]);

   if(!reclaim || !pullback) return;

   // 3) The most recent EMA3/EMA9 cross before the pullback must be a cross UP (bullish)
   int crossBar = FindRecentCrossBar(ema3, ema9);
   if(crossBar < 0) return;
   bool bullishCross = (ema3[crossBar] > ema9[crossBar] && ema3[crossBar+1] <= ema9[crossBar+1]);
   if(!bullishCross) return;

   // 4) Optional trend filter
   if(Trend_Filter && !(ema3[1] > ema9[1]))
   {
      if(Verbose_Log) Print("BUY skipped by trend filter (EMA3 not above EMA9)");
      return;
   }

   if(!IsTradingTime()) return;

   // Stop = lowest low of the pullback + entry candles; TP = same distance (1:1)
   double sl   = MathMin(l1, l2);
   double risk = c1 - sl;
   if(risk <= 0) return;
   double tp   = c1 + risk;

   int enCand = crossBar;        // entry candle number (cross = candle 1)
   int pbCand = crossBar - 1;    // pullback candle number

   if(Verbose_Log)
      Print(StringFormat("BUY: cross=cand1 PB=cand%d EN=cand%d | PB O=%.2f C=%.2f E9=%.2f | EN O=%.2f C=%.2f E9=%.2f",
            pbCand, enCand, o2, c2, ema9[2], o1, c1, ema9[1]));

   if(Draw_Markers)
   {
      DrawArrow(iTime(_Symbol, PERIOD_CURRENT, 2), iHigh(_Symbol, PERIOD_CURRENT, 2), OBJ_ARROW_DOWN, clrYellow);
      DrawArrow(iTime(_Symbol, PERIOD_CURRENT, 1), l1, OBJ_ARROW_UP, clrDodgerBlue);
      DrawLabel(iTime(_Symbol, PERIOD_CURRENT, 1), l1,
         StringFormat("cross=cand1 PB=cand%d EN=cand%d | PB O%.2f C%.2f E9=%.2f | EN O%.2f C%.2f E9=%.2f | EMA3=%.2f",
            pbCand, enCand, o2, c2, ema9[2], o1, c1, ema9[1], ema3[1]), clrWhite);
   }

   ExecuteBuy(sl, tp, risk);
}

//+------------------------------------------------------------------+
//| SELL pattern - mirror of buy                                       |
//+------------------------------------------------------------------+
void CheckSell(const double &ema3[], const double &ema9[])
{
   if(!Enable_Sell) return;
   if(One_Trade_At_A_Time && HasOpenPosition()) return;

   double o1 = iOpen(_Symbol, PERIOD_CURRENT, 1);   // entry candle
   double h1 = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double c1 = iClose(_Symbol,PERIOD_CURRENT, 1);
   double o2 = iOpen(_Symbol, PERIOD_CURRENT, 2);   // pullback candle
   double h2 = iHigh(_Symbol, PERIOD_CURRENT, 2);
   double c2 = iClose(_Symbol,PERIOD_CURRENT, 2);

   // 1) Entry candle = bearish reclaim: opens above EMA9, closes below EMA9
   bool reclaim = (o1 > ema9[1] && c1 < ema9[1]);

   // 2) Pullback candle = bullish: opens below EMA9, closes above EMA9
   bool pullback = (c2 > o2 && o2 < ema9[2] && c2 > ema9[2]);

   if(!reclaim || !pullback) return;

   // 3) The most recent EMA3/EMA9 cross before the pullback must be a cross DOWN (bearish)
   int crossBar = FindRecentCrossBar(ema3, ema9);
   if(crossBar < 0) return;
   bool bearishCross = (ema3[crossBar] < ema9[crossBar] && ema3[crossBar+1] >= ema9[crossBar+1]);
   if(!bearishCross) return;

   // 4) Optional trend filter
   if(Trend_Filter && !(ema3[1] < ema9[1]))
   {
      if(Verbose_Log) Print("SELL skipped by trend filter (EMA3 not below EMA9)");
      return;
   }

   if(!IsTradingTime()) return;

   double sl   = MathMax(h1, h2);
   double risk = sl - c1;
   if(risk <= 0) return;
   double tp   = c1 - risk;

   int enCand = crossBar;
   int pbCand = crossBar - 1;

   if(Verbose_Log)
      Print(StringFormat("SELL: cross=cand1 PB=cand%d EN=cand%d | PB O=%.2f C=%.2f E9=%.2f | EN O=%.2f C=%.2f E9=%.2f",
            pbCand, enCand, o2, c2, ema9[2], o1, c1, ema9[1]));

   if(Draw_Markers)
   {
      DrawArrow(iTime(_Symbol, PERIOD_CURRENT, 2), iLow(_Symbol, PERIOD_CURRENT, 2), OBJ_ARROW_UP, clrYellow);
      DrawArrow(iTime(_Symbol, PERIOD_CURRENT, 1), h1, OBJ_ARROW_DOWN, clrRed);
      DrawLabel(iTime(_Symbol, PERIOD_CURRENT, 1), h1,
         StringFormat("cross=cand1 PB=cand%d EN=cand%d | PB O%.2f C%.2f E9=%.2f | EN O%.2f C%.2f E9=%.2f | EMA3=%.2f",
            pbCand, enCand, o2, c2, ema9[2], o1, c1, ema9[1], ema3[1]), clrWhite);
   }

   ExecuteSell(sl, tp, risk);
}

//+------------------------------------------------------------------+
//| Find the bar index of the most recent EMA3/EMA9 cross that sits    |
//| before the pullback candle. Pullback = bar 2, so a cross that      |
//| makes the pullback "candle P" (P = 2..Max_Pullback_Candle) sits at |
//| bar 3..(Max_Pullback_Candle+1). Returns -1 if none in range.       |
//+------------------------------------------------------------------+
int FindRecentCrossBar(const double &ema3[], const double &ema9[])
{
   for(int k = 3; k <= Max_Pullback_Candle + 1; k++)
   {
      bool crossedUp   = (ema3[k] > ema9[k] && ema3[k+1] <= ema9[k+1]);
      bool crossedDown = (ema3[k] < ema9[k] && ema3[k+1] >= ema9[k+1]);
      if(crossedUp || crossedDown)
         return k;   // nearest cross to the pullback
   }
   return -1;
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
      "====== EMA Crossover EA v3.9 ======\n"
      "EMA %d: %.2f  |  EMA %d: %.2f  (%s)\n"
      "Risk: %.2f%%  |  Buy:%s  Sell:%s  Trend filter:%s\n"
      "Pullback allowed: candle 2 to %d (cross = candle 1)\n"
      "Trading: %s%s\n"
      "===================================",
      EMA_Fast_Period, emaFastVal, EMA_Slow_Period, emaSlowVal, align,
      Risk_Percent, (Enable_Buy ? "on" : "off"), (Enable_Sell ? "on" : "off"),
      (Trend_Filter ? "on" : "off"),
      Max_Pullback_Candle,
      tradingStatus, tradeInfo
   ));
}
//+------------------------------------------------------------------+
