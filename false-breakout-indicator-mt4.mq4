//+------------------------------------------------------------------+
//|                                false-breakout-indicator-mt4.mq4  |
//|                                Copyright mt4indicators.com       |
//|                                https://mt4indicators.com         |
//+------------------------------------------------------------------+
#property copyright   "mt4indicators.com"
#property link        "https://mt4indicators.com/mt4-indicator/false-breakout-indicator-mt4/"
#property version     "1.00"
#property description "False breakout (fakeout) detector. Builds a range from RangeBars candles,"
#property description "then marks the closed candle that closes back inside the range after price"
#property description "traded beyond it within ConfirmBars candles. Closed candles only; arrows"
#property description "never move or disappear."
#property strict

#property indicator_chart_window
#property indicator_buffers 2

//--- inputs
input int    RangeBars     = 20;            // Candles used to build the range (before the signal window)
input int    ConfirmBars   = 3;             // Candles allowed for the poke and the close back inside
input double MinPokePoints = 0.0;           // Minimum distance beyond the range, in points (0 = any)
input int    MaxBarsBack   = 2000;          // How many candles of history to scan
input bool   DrawRange     = true;          // Draw the range high and low as short segments
input color  BullColor     = clrDodgerBlue; // Bullish fakeout (failed breakdown) color
input color  BearColor     = clrRed;        // Bearish fakeout (failed breakout) color
input color  RangeColor    = clrSlateGray;  // Range segment color
input bool   AlertsOn      = false;         // Pop-up alert on a new fakeout
input bool   PushOn        = false;         // Push notification to MT4 mobile
input bool   SoundOn       = false;         // Play a sound on a new fakeout
input string SoundFile     = "alert.wav";   // Sound file

//--- buffers
double BullBuf[];
double BearBuf[];

#define PFX "FBO_"

int      g_rb;
int      g_cb;
datetime g_lastAlertBar = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   g_rb = MathMax(2, RangeBars);
   g_cb = MathMax(1, ConfirmBars);

   SetIndexBuffer(0, BullBuf);
   SetIndexStyle(0, DRAW_ARROW, STYLE_SOLID, 2, BullColor);
   SetIndexArrow(0, 233);
   SetIndexLabel(0, "Bullish fakeout");
   SetIndexEmptyValue(0, EMPTY_VALUE);

   SetIndexBuffer(1, BearBuf);
   SetIndexStyle(1, DRAW_ARROW, STYLE_SOLID, 2, BearColor);
   SetIndexArrow(1, 234);
   SetIndexLabel(1, "Bearish fakeout");
   SetIndexEmptyValue(1, EMPTY_VALUE);

   IndicatorShortName("False Breakout (" + IntegerToString(g_rb) + ", " + IntegerToString(g_cb) + ")");
   IndicatorDigits(_Digits);
   g_lastAlertBar = 0;
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   ObjectsDeleteAll(0, PFX);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
void DrawSegment(const string name, const datetime t1, const datetime t2, const double price)
  {
   if(ObjectFind(0, name) >= 0)
      return;
   if(!ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price))
      return;
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_COLOR, RangeColor);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
  }

//+------------------------------------------------------------------+
//| true if a same-direction signal exists in the ConfirmBars candles |
//| before bar s (prevents several arrows for one breakout)          |
//+------------------------------------------------------------------+
bool RecentSignal(const double &buf[], const int s, const int total)
  {
   for(int j = s + 1; j <= s + g_cb && j <= total - 1; j++)
      if(buf[j] != EMPTY_VALUE)
         return(true);
   return(false);
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   // signal bar s, signal window s ... s+cb-1, range s+cb ... s+cb+rb-1
   int maxS = rates_total - g_cb - g_rb;
   if(maxS < 1)
      return(0);

   ArraySetAsSeries(time, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);

   int start;
   if(prev_calculated <= 0)
     {
      ArrayInitialize(BullBuf, EMPTY_VALUE);
      ArrayInitialize(BearBuf, EMPTY_VALUE);
      ObjectsDeleteAll(0, PFX);
      start = (MaxBarsBack > 0 && MaxBarsBack < maxS) ? MaxBarsBack : maxS;
      g_lastAlertBar = time[0];              // no alerts for signals that existed before loading
     }
   else
     {
      start = rates_total - prev_calculated + 1;   // 1 on a tick, 2 on a new bar
      if(start > maxS)
         start = maxS;
     }
   if(start < 1)
      start = 1;

   double poke = MathMax(0.0, MinPokePoints) * _Point;
   string newSignal = "";

   //--- the live candle never carries a signal
   BullBuf[0] = EMPTY_VALUE;
   BearBuf[0] = EMPTY_VALUE;

   //--- closed candles only, oldest to newest (the duplicate filter looks at older results)
   for(int s = start; s >= 1; s--)
     {
      BullBuf[s] = EMPTY_VALUE;
      BearBuf[s] = EMPTY_VALUE;

      //--- range
      int    r0 = s + g_cb;
      double rh = high[r0];
      double rl = low[r0];
      for(int k = 1; k < g_rb; k++)
        {
         if(high[r0 + k] > rh) rh = high[r0 + k];
         if(low[r0 + k]  < rl) rl = low[r0 + k];
        }
      if(rh <= rl)
         continue;

      // the signal candle must close back inside the range
      if(close[s] >= rh || close[s] <= rl)
         continue;

      //--- bearish: a candle in the window traded above the range high, every candle
      //    after it (before s) closed at or above the high, and s is the first close back inside
      bool bear = false;
      for(int b = s; b <= s + g_cb - 1; b++)
        {
         if(b > s && close[b] < rh)
            break;                                    // an earlier candle was already back inside
         if(high[b] > rh && high[b] - rh >= poke)
           {
            bear = true;
            break;
           }
        }

      //--- bullish: the mirror image below the range low
      bool bull = false;
      for(int b = s; b <= s + g_cb - 1; b++)
        {
         if(b > s && close[b] > rl)
            break;
         if(low[b] < rl && rl - low[b] >= poke)
           {
            bull = true;
            break;
           }
        }

      if(bear && RecentSignal(BearBuf, s, rates_total))
         bear = false;
      if(bull && RecentSignal(BullBuf, s, rates_total))
         bull = false;

      if(!bear && !bull)
         continue;

      double gap = iATR(NULL, 0, 14, s) * 0.4;
      if(gap <= 0.0)
         gap = (high[s] - low[s]) * 0.4;

      if(bear)
         BearBuf[s] = high[s] + gap;
      if(bull)
         BullBuf[s] = low[s] - gap;

      if(DrawRange)
        {
         string tag = PFX + IntegerToString((long)time[s]);
         DrawSegment(tag + "_H", time[r0 + g_rb - 1], time[s], rh);
         DrawSegment(tag + "_L", time[r0 + g_rb - 1], time[s], rl);
        }

      if(s == 1)
        {
         if(bear && bull)
            newSignal = "Two-sided fakeout";
         else if(bear)
            newSignal = "Bearish fakeout (failed breakout above " + DoubleToString(rh, _Digits) + ")";
         else
            newSignal = "Bullish fakeout (failed breakdown below " + DoubleToString(rl, _Digits) + ")";
        }
     }

   //--- alerts, once per bar, for the candle that just closed
   if(newSignal != "" && prev_calculated > 0 && time[0] != g_lastAlertBar)
     {
      g_lastAlertBar = time[0];
      string text = newSignal + " on " + Symbol() + " " + IntegerToString(Period()) + "m";
      if(AlertsOn)
         Alert(text);
      if(PushOn)
         SendNotification(text);
      if(SoundOn)
         PlaySound(SoundFile);
     }

   return(rates_total);
  }
//+------------------------------------------------------------------+
