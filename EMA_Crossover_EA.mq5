//+------------------------------------------------------------------+
//|                                          EMA_Crossover_EA.mq5     |
//|                                          Copyright 2026            |
//|              Gold Scalper - EMA Trend + RSI Pullback Entry         |
//+------------------------------------------------------------------+
#property copyright "Gold Scalper EA v3.0"
#property version   "3.00"
#property description "EMA Trend Direction + RSI Pullback Entry"
#property description "Designed for Gold (XAUUSD) on M5 timeframe"
#property description "More active trading with proper risk management"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                   |
//+------------------------------------------------------------------+

input group "══════ EMA Settings ══════"
input int      EMA_Fast_Period   = 21;         // EMA Fast Period (signal)
input int      EMA_Slow_Period   = 50;         // EMA Slow Period (trend)
input int      EMA_Filter_Period = 200;        // EMA Filter (overall direction)

input group "══════ RSI Settings ══════"
input int      RSI_Period        = 14;         // RSI Period
input double   RSI_Buy_Level     = 40.0;       // RSI Buy zone (pullback below this = entry)
input double   RSI_Sell_Level    = 60.0;       // RSI Sell zone (pullback above this = entry)
input double   RSI_OB_Level      = 75.0;       // RSI overbought (avoid new buys)
input double   RSI_OS_Level      = 25.0;       // RSI oversold (avoid new sells)

input group "══════ Time Filter (Server Time) ══════"
input int      Market_Open_Hour  = 1;          // Daily Market Open Hour
input int      Market_Open_Min   = 0;          // Daily Market Open Minute
input int      Market_Close_Hour = 23;         // Daily Market Close Hour
input int      Market_Close_Min  = 59;         // Daily Market Close Minute
input int      Open_Delay_Min    = 30;         // Minutes after open to start trading
input int      Close_Before_Min  = 10;         // Minutes before close to exit all trades

input group "══════ Trade Settings ══════"
input double   Lot_Size          = 0.01;       // Lot Size
input double   Stop_Loss_Pts     = 300.0;      // Stop Loss (points, 0 = disabled)
input double   Take_Profit_Pts   = 500.0;      // Take Profit (points, 0 = disabled)
input int      Max_Trades        = 3;          // Maximum simultaneous trades
input int      Magic_Number      = 202601;     // Magic Number
input int      Max_Slippage      = 30;         // Maximum Slippage (points)
input int      Min_Bars_Between  = 5;          // Minimum bars between trades

input group "══════ Telegram Alerts ══════"
input string   Telegram_Token    = "";         // Telegram Bot Token
input string   Telegram_ChatID   = "";         // Telegram Chat ID
input bool     Alert_On_Trade    = true;       // Send alert on trade open/close

//+------------------------------------------------------------------+
//| Global Variables                                                   |
//+------------------------------------------------------------------+

int    g_handleEMAFast;
int    g_handleEMASlow;
int    g_handleEMAFilter;
int    g_handleRSI;
CTrade g_trade;

datetime g_lastBarTime   = 0;
datetime g_lastTradeBar  = 0;
int      g_barCount      = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   g_handleEMAFast   = iMA(_Symbol, PERIOD_CURRENT, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEMASlow   = iMA(_Symbol, PERIOD_CURRENT, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_handleEMAFilter = iMA(_Symbol, PERIOD_CURRENT, EMA_Filter_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_handleRSI       = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);

   if(g_handleEMAFast == INVALID_HANDLE || g_handleEMASlow == INVALID_HANDLE ||
      g_handleEMAFilter == INVALID_HANDLE || g_handleRSI == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicators");
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber(Magic_Number);
   g_trade.SetDeviationInPoints(Max_Slippage);

   string msg = StringFormat("Gold Scalper v3.0 Started | %s | Balance: $%.2f | AutoTrading: %s",
                _Symbol, AccountInfoDouble(ACCOUNT_BALANCE),
                (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ? "ON" : "OFF"));
   Print(msg);
   SendTelegram(msg);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_handleEMAFast   != INVALID_HANDLE) IndicatorRelease(g_handleEMAFast);
   if(g_handleEMASlow   != INVALID_HANDLE) IndicatorRelease(g_handleEMASlow);
   if(g_handleEMAFilter != INVALID_HANDLE) IndicatorRelease(g_handleEMAFilter);
   if(g_handleRSI       != INVALID_HANDLE) IndicatorRelease(g_handleRSI);
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   if(IsCloseTime())
   {
      CloseAllTrades("End of day");
      return;
   }

   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   bool newBar = (barTime != g_lastBarTime);
   if(!newBar) return;
   g_lastBarTime = barTime;
   g_barCount++;

   double emaFast[3], emaSlow[3], emaFilter[3], rsi[3];
   if(CopyBuffer(g_handleEMAFast,   0, 0, 3, emaFast)   < 3) return;
   if(CopyBuffer(g_handleEMASlow,   0, 0, 3, emaSlow)   < 3) return;
   if(CopyBuffer(g_handleEMAFilter, 0, 0, 3, emaFilter) < 3) return;
   if(CopyBuffer(g_handleRSI,       0, 0, 3, rsi)       < 3) return;
   ArraySetAsSeries(emaFast,   true);
   ArraySetAsSeries(emaSlow,   true);
   ArraySetAsSeries(emaFilter, true);
   ArraySetAsSeries(rsi,       true);

   CheckTrailingStop();
   UpdateChartComment(emaFast[1], emaSlow[1], emaFilter[1], rsi[1]);

   if(!IsTradingTime()) return;
   if(CountOpenTrades() >= Max_Trades) return;
   if(g_barCount - BarsSinceLastTrade() < Min_Bars_Between) return;

   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double close2 = iClose(_Symbol, PERIOD_CURRENT, 2);

   // Trend direction: EMA Fast above Slow = bullish, below = bearish
   bool bullishTrend = (emaFast[1] > emaSlow[1]) && (close1 > emaFilter[1]);
   bool bearishTrend = (emaFast[1] < emaSlow[1]) && (close1 < emaFilter[1]);

   // BUY: Bullish trend + RSI pulled back below buy level then recovered
   if(bullishTrend)
   {
      if(rsi[2] < RSI_Buy_Level && rsi[1] >= RSI_Buy_Level && rsi[1] < RSI_OB_Level)
      {
         if(close1 > emaFast[1])
            ExecuteBuy();
      }
      // Alternative: price bounced off EMA fast
      else if(rsi[1] > RSI_Buy_Level && rsi[1] < RSI_OB_Level)
      {
         double low1 = iLow(_Symbol, PERIOD_CURRENT, 1);
         if(low1 <= emaFast[1] * 1.001 && close1 > emaFast[1])
            ExecuteBuy();
      }
   }

   // SELL: Bearish trend + RSI pulled back above sell level then dropped
   if(bearishTrend)
   {
      if(rsi[2] > RSI_Sell_Level && rsi[1] <= RSI_Sell_Level && rsi[1] > RSI_OS_Level)
      {
         if(close1 < emaFast[1])
            ExecuteSell();
      }
      // Alternative: price rejected from EMA fast
      else if(rsi[1] < RSI_Sell_Level && rsi[1] > RSI_OS_Level)
      {
         double high1 = iHigh(_Symbol, PERIOD_CURRENT, 1);
         if(high1 >= emaFast[1] * 0.999 && close1 < emaFast[1])
            ExecuteSell();
      }
   }
}

//+------------------------------------------------------------------+
//| Execute BUY trade                                                  |
//+------------------------------------------------------------------+
void ExecuteBuy()
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double lot = NormalizeLot(Lot_Size);

   double sl = 0, tp = 0;
   if(Stop_Loss_Pts > 0)
      sl = NormalizeDouble(price - Stop_Loss_Pts * _Point, _Digits);
   if(Take_Profit_Pts > 0)
      tp = NormalizeDouble(price + Take_Profit_Pts * _Point, _Digits);

   if(g_trade.Buy(lot, _Symbol, price, sl, tp, "GoldScalper Buy"))
   {
      ulong ticket = g_trade.ResultOrder();
      g_lastTradeBar = g_lastBarTime;
      string msg = StringFormat("BUY OPENED #%d | Price: %.2f | SL: %.2f | TP: %.2f | Lot: %.2f",
                   ticket, price, sl, tp, lot);
      Print(msg);
      if(Alert_On_Trade) SendTelegram(msg);
   }
   else
      Print("BUY FAILED: ", g_trade.ResultRetcode(), " - ", g_trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Execute SELL trade                                                 |
//+------------------------------------------------------------------+
void ExecuteSell()
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double lot = NormalizeLot(Lot_Size);

   double sl = 0, tp = 0;
   if(Stop_Loss_Pts > 0)
      sl = NormalizeDouble(price + Stop_Loss_Pts * _Point, _Digits);
   if(Take_Profit_Pts > 0)
      tp = NormalizeDouble(price - Take_Profit_Pts * _Point, _Digits);

   if(g_trade.Sell(lot, _Symbol, price, sl, tp, "GoldScalper Sell"))
   {
      ulong ticket = g_trade.ResultOrder();
      g_lastTradeBar = g_lastBarTime;
      string msg = StringFormat("SELL OPENED #%d | Price: %.2f | SL: %.2f | TP: %.2f | Lot: %.2f",
                   ticket, price, sl, tp, lot);
      Print(msg);
      if(Alert_On_Trade) SendTelegram(msg);
   }
   else
      Print("SELL FAILED: ", g_trade.ResultRetcode(), " - ", g_trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Simple trailing stop - move SL to breakeven after 50% of TP       |
//+------------------------------------------------------------------+
void CheckTrailingStop()
{
   if(Stop_Loss_Pts <= 0 || Take_Profit_Pts <= 0) return;

   double breakEvenTrigger = Take_Profit_Pts * 0.5 * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Magic_Number) continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      long posType = PositionGetInteger(POSITION_TYPE);

      if(posType == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(bid - openPrice >= breakEvenTrigger && currentSL < openPrice)
         {
            double newSL = NormalizeDouble(openPrice + 10 * _Point, _Digits);
            g_trade.PositionModify(ticket, newSL, tp);
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(openPrice - ask >= breakEvenTrigger && (currentSL > openPrice || currentSL == 0))
         {
            double newSL = NormalizeDouble(openPrice - 10 * _Point, _Digits);
            g_trade.PositionModify(ticket, newSL, tp);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Count open trades with this magic number                           |
//+------------------------------------------------------------------+
int CountOpenTrades()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == Magic_Number)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Bars since last trade                                              |
//+------------------------------------------------------------------+
int BarsSinceLastTrade()
{
   if(g_lastTradeBar == 0) return Min_Bars_Between + 1;
   int bars = 0;
   datetime current = g_lastBarTime;
   while(current > g_lastTradeBar && bars < 1000)
   {
      bars++;
      current -= PeriodSeconds(PERIOD_CURRENT);
   }
   return bars;
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
void CloseAllTrades(string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == Magic_Number)
         {
            double profit = PositionGetDouble(POSITION_PROFIT);
            if(g_trade.PositionClose(ticket))
            {
               string msg = StringFormat("CLOSED #%d | Reason: %s | P/L: $%.2f", ticket, reason, profit);
               Print(msg);
               if(Alert_On_Trade) SendTelegram(msg);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Send Telegram message                                              |
//+------------------------------------------------------------------+
void SendTelegram(string message)
{
   if(Telegram_Token == "" || Telegram_ChatID == "") return;

   string url = "https://api.telegram.org/bot" + Telegram_Token + "/sendMessage";
   string params = "chat_id=" + Telegram_ChatID + "&text=" + message;

   char post[];
   char result[];
   string headers = "Content-Type: application/x-www-form-urlencoded\r\n";
   StringToCharArray(params, post);

   int res = WebRequest("POST", url, headers, 5000, post, result, headers);
   if(res != 200)
      Print("Telegram send failed, code: ", res);
}

//+------------------------------------------------------------------+
//| Update chart comment                                               |
//+------------------------------------------------------------------+
void UpdateChartComment(double emaFastVal, double emaSlowVal, double emaFilterVal, double rsiVal)
{
   string trend = "FLAT";
   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   if(emaFastVal > emaSlowVal && close1 > emaFilterVal) trend = "BULLISH";
   else if(emaFastVal < emaSlowVal && close1 < emaFilterVal) trend = "BEARISH";

   string tradingStatus = IsTradingTime() ? "ACTIVE" : "PAUSED";
   if(IsCloseTime()) tradingStatus = "CLOSING";

   int openTrades = CountOpenTrades();

   Comment(StringFormat(
      "══════ Gold Scalper v3.0 ══════\n"
      "EMA %d: %.2f  |  EMA %d: %.2f  |  EMA %d: %.2f\n"
      "RSI(%d): %.2f\n"
      "Trend: %s  |  Trading: %s\n"
      "Open Trades: %d / %d\n"
      "Balance: $%.2f  |  Equity: $%.2f\n"
      "═══════════════════════════════",
      EMA_Fast_Period, emaFastVal,
      EMA_Slow_Period, emaSlowVal,
      EMA_Filter_Period, emaFilterVal,
      RSI_Period, rsiVal,
      trend, tradingStatus,
      openTrades, Max_Trades,
      AccountInfoDouble(ACCOUNT_BALANCE),
      AccountInfoDouble(ACCOUNT_EQUITY)
   ));
}
//+------------------------------------------------------------------+
