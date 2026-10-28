//+------------------------------------------------------------------+
//|  BLACK CUBE BRIDGE EA - PRO DASHBOARD                            |
//+------------------------------------------------------------------+
#property copyright "2026 © Black Cube Code - Support and Donation QRIS"
#property link      "https://lynk.id/blackcubecode"
#property description "BlackCube TradingView -> Python file-queue bridge EA"
#property description "Not Financial Advice. Past performance does not guarantee profit future."
#property description "------------------------------------------------------------------"
#property description "Free Signal Trading XAUUSD : t.me/blackcubecode"
#property description "Free Bot Trading AI XAUUSD : t.me/blackcubecodeAI_bot"
#property version   "1.10"
#property icon "bcc.ico"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//--- INPUT ----------------------------------------------------------
input string InpSymbol = "XAUUSD";
input double InpRiskPercent = 0.25;        // Risk per trade as % of equity
input double InpMaxSpreadPoints = 80;      // Broker points; calibrate for your symbol
input int    InpMaxOpenPositions = 1;      // Positions for this symbol + magic
input ulong  InpMagic = 610281;
input int    InpPollSeconds = 1;
input bool   InpAllowLiveAccount = false;  // Real Akun (True) Akun Demo (False)
input bool   InpRequireSLTP = true;
input bool   InpOnePositionPerSymbol = true;

//--- DASHBOARD INPUTS ----------------------------------------------
//== Dashboard ==="
bool   InpShowDashboard = true;      // Tampilkan dashboard di chart
int    InpDashX = 10;                // Dashboard X position (pixels)
int    InpDashY = 30;                // Dashboard Y position (pixels)
int    InpDashWidth = 320;           // Dashboard width (pixels)
color  InpDashBgColor = C'20,25,35'; // Background color
color  InpDashTitleColor = C'0,150,255'; // Title bar color
color  InpDashTextColor = clrWhite;  // Text color
color  InpDashOkColor = C'0,220,100'; // OK/success color
color  InpDashWarnColor = C'255,180,0'; // Warning color
color  InpDashErrColor = C'255,60,60'; // Error color
bool   InpDashShowLog = true;        // Tampilkan log aktivitas terakhir

//--- DIRECTORIES ----------------------------------------------------
string QUEUE_DIR = "BlackCube\\inbox";
string DONE_DIR  = "BlackCube\\processed";
string FAIL_DIR  = "BlackCube\\rejected";

//--- DASHBOARD STATE ------------------------------------------------
string   g_dashName = "BC_Dashboard";
int      g_logScrollIdx = 0;
string   g_logLines[10];
int      g_logCount = 0;
datetime g_lastPollTime = 0;
datetime g_lastSignalTime = 0;
string   g_lastSignalId = "";
string   g_lastSignalAction = "";
string   g_lastSignalResult = "";
int      g_statProcessed = 0;
int      g_statRejected = 0;
int      g_statExecuted = 0;
double   g_lastExecLots = 0.0;
ulong    g_lastTicket = 0;
string   g_eaState = "INITIALIZING";

//+------------------------------------------------------------------+
//| Helper: format status ke log dashboard                           |
//+------------------------------------------------------------------+
void DashLog(string msg, color col = clrWhite)
{
   if(!InpShowDashboard) return;
   g_logLines[g_logScrollIdx] = TimeToString(TimeCurrent(), TIME_MINUTES|TIME_SECONDS) + " " + msg;
   g_logScrollIdx = (g_logScrollIdx + 1) % 10;
   if(g_logCount < 10) g_logCount++;
}

//+------------------------------------------------------------------+
//| Cek akun demo                                                    |
//+------------------------------------------------------------------+
bool IsDemoAccount()
{
   return (AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO);
}

//+------------------------------------------------------------------+
//| Cek sudah diproses                                               |
//+------------------------------------------------------------------+
bool AlreadyProcessed(string id)
{
   string filename = "BlackCube\\processed_ids\\" + id + ".txt";
   int h = FileOpen(filename, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h != INVALID_HANDLE)
   {
      FileClose(h);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Tandai diproses                                                  |
//+------------------------------------------------------------------+
void MarkProcessed(string id, string status)
{
   FolderCreate("BlackCube\\processed_ids", FILE_COMMON);
   string filename = "BlackCube\\processed_ids\\" + id + ".txt";
   int h = FileOpen(filename, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h != INVALID_HANDLE)
   {
      FileWriteString(h, status + "\n");
      FileClose(h);
   }
}

//+------------------------------------------------------------------+
//| Normalisasi volume                                               |
//+------------------------------------------------------------------+
double NormalizeVolume(double lots)
{
   double minLot = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(InpSymbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) return 0.0;
   lots = MathMin(maxLot, lots);
   lots = MathFloor(lots / step) * step;
   lots = NormalizeDouble(lots, 2);
   if(lots < minLot) return 0.0;
   return lots;
}

//+------------------------------------------------------------------+
//| Hitung lot dari risk %                                           |
//+------------------------------------------------------------------+
double CalculateRiskLots(ENUM_ORDER_TYPE orderType, double entry, double sl)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPercent / 100.0;
   double profitAtSL = 0.0;
   if(riskMoney <= 0 || sl <= 0 || entry <= 0 || entry == sl) return 0.0;
   if(!OrderCalcProfit(orderType, InpSymbol, 1.0, entry, sl, profitAtSL))
      return 0.0;
   double lossPerLot = MathAbs(profitAtSL);
   if(lossPerLot <= 0) return 0.0;
   return NormalizeVolume(riskMoney / lossPerLot);
}

//+------------------------------------------------------------------+
//| Hitung posisi EA kita                                            |
//+------------------------------------------------------------------+
int CountOurPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == InpSymbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Validasi SL/TP                                                   |
//+------------------------------------------------------------------+
bool ValidStops(string action, double entry, double sl, double tp)
{
   if(!InpRequireSLTP) return true;
   if(sl <= 0 || tp <= 0) return false;
   if(action == "buy") return (sl < entry && tp > entry);
   if(action == "sell") return (tp < entry && sl > entry);
   return false;
}

//+------------------------------------------------------------------+
//| Pindahkan file ke rejected                                       |
//+------------------------------------------------------------------+
void RejectFile(string filename, string reason)
{
   Print("Rejected command ", filename, ": ", reason);
   DashLog("REJECT " + filename + " : " + reason, InpDashErrColor);
   g_statRejected++;
   FolderCreate(FAIL_DIR, FILE_COMMON);
   string target = FAIL_DIR + "\\" + filename;
   FileMove(QUEUE_DIR + "\\" + filename, FILE_COMMON, target, FILE_COMMON|FILE_REWRITE);
}

//+------------------------------------------------------------------+
//| Proses satu file JSON                                            |
//+------------------------------------------------------------------+
void ProcessFile(string filename)
{
   string full = QUEUE_DIR + "\\" + filename;
   int h = FileOpen(full, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   string json = "";
   while(!FileIsEnding(h))
      json += FileReadString(h);
   FileClose(h);

   string id = JsonString(json, "id");
   string action = JsonString(json, "action");
   string symbol = JsonString(json, "symbol");
   double sl = JsonNumber(json, "sl");
   double tp = JsonNumber(json, "tp");
   double signalPrice = JsonNumber(json, "price");

   g_lastSignalId = id;
   g_lastSignalAction = action;
   g_lastSignalTime = TimeCurrent();

   if(id == "" || (action != "buy" && action != "sell") || symbol != InpSymbol)
   {
      g_lastSignalResult = "invalid";
      RejectFile(filename, "invalid id/action/symbol");
      return;
   }

   if(AlreadyProcessed(id))
   {
      g_lastSignalResult = "duplicate";
      FileDelete(full, FILE_COMMON);
      DashLog("DUPLICATE " + id, InpDashWarnColor);
      return;
   }

   if(!IsDemoAccount() && !InpAllowLiveAccount)
   {
      g_lastSignalResult = "live-disabled";
      RejectFile(filename, "live account disabled by EA input");
      MarkProcessed(id, "rejected-live-disabled");
      return;
   }

   if(!TerminalInfoInteger(TERMINAL_CONNECTED) ||
      !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return;

   if(!SymbolSelect(InpSymbol, true))
   {
      g_lastSignalResult = "symbol-unavailable";
      RejectFile(filename, "symbol unavailable");
      MarkProcessed(id, "rejected-symbol");
      return;
   }

   MqlTick tick;
   if(!SymbolInfoTick(InpSymbol, tick) || tick.ask <= 0 || tick.bid <= 0)
      return;

   double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   if(point <= 0) return;
   double spreadPoints = (tick.ask - tick.bid) / point;
   if(spreadPoints > InpMaxSpreadPoints)
   {
      g_lastSignalResult = "spread";
      RejectFile(filename, "spread too high");
      MarkProcessed(id, "rejected-spread");
      return;
   }

   if(CountOurPositions() >= InpMaxOpenPositions)
   {
      g_lastSignalResult = "max-positions";
      RejectFile(filename, "max open positions reached");
      MarkProcessed(id, "rejected-max-positions");
      return;
   }

   if(InpOnePositionPerSymbol && PositionSelect(InpSymbol))
   {
      g_lastSignalResult = "existing-position";
      RejectFile(filename, "position already exists on symbol");
      MarkProcessed(id, "rejected-existing-position");
      return;
   }

   ENUM_ORDER_TYPE orderType = (action == "buy" ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double entry = (action == "buy" ? tick.ask : tick.bid);
   int digits = (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   //--- DEBUG: log harga aktual (bisa dihapus di produksi) ---
   Print("DEBUG id=", id, " action=", action,
         " entry=", entry, " sl=", sl, " tp=", tp,
         " payload_price=", signalPrice,
         " tick_bid=", tick.bid, " tick_ask=", tick.ask);

   if(!ValidStops(action, entry, sl, tp))
   {
      g_lastSignalResult = "rejected-stops";
      RejectFile(filename, "SL/TP invalid relative to current market price");
      MarkProcessed(id, "rejected-stops");
      return;
   }

   long stopsLevel = SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = stopsLevel * point;
   if(action == "buy" && (entry - sl < minDistance || tp - entry < minDistance))
   {
      g_lastSignalResult = "rejected-stop-distance";
      RejectFile(filename, "stops inside broker minimum distance");
      MarkProcessed(id, "rejected-stop-distance");
      return;
   }
   if(action == "sell" && (sl - entry < minDistance || entry - tp < minDistance))
   {
      g_lastSignalResult = "rejected-stop-distance";
      RejectFile(filename, "stops inside broker minimum distance");
      MarkProcessed(id, "rejected-stop-distance");
      return;
   }

   double lots = CalculateRiskLots(orderType, entry, sl);
   if(lots <= 0)
   {
      g_lastSignalResult = "rejected-lot";
      RejectFile(filename, "risk lot below minimum or unable to calculate");
      MarkProcessed(id, "rejected-lot");
      return;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFillingBySymbol(InpSymbol);
   string comment = "BC_" + StringSubstr(id, 0, 20);
   bool sent = false;
   if(action == "buy")
      sent = trade.Buy(lots, InpSymbol, 0.0, sl, tp, comment);
   else
      sent = trade.Sell(lots, InpSymbol, 0.0, sl, tp, comment);

   uint retcode = trade.ResultRetcode();
   if(sent && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED ||
               retcode == TRADE_RETCODE_DONE_PARTIAL))
   {
      g_statExecuted++;
      g_lastExecLots = lots;
      g_lastTicket = trade.ResultOrder();
      g_lastSignalResult = "EXECUTED";
      MarkProcessed(id, "executed");
      Print("Executed id=", id, " action=", action, " lots=", lots,
            " sl=", sl, " tp=", tp, " retcode=", retcode);
      DashLog("EXEC " + action + " " + DoubleToString(lots, 2) + " @ " +
              DoubleToString(entry, digits) + " [" + id + "]", InpDashOkColor);
      FileDelete(full, FILE_COMMON);
   }
   else
   {
      Print("Order failed id=", id, " retcode=", retcode,
            " description=", trade.ResultRetcodeDescription());
      DashLog("FAIL " + id + " : " + trade.ResultRetcodeDescription(), InpDashErrColor);
      g_lastSignalResult = "failed-" + IntegerToString(retcode);
      if(retcode == TRADE_RETCODE_INVALID_STOPS || retcode == TRADE_RETCODE_INVALID_VOLUME ||
         retcode == TRADE_RETCODE_NO_MONEY || retcode == TRADE_RETCODE_MARKET_CLOSED)
      {
         RejectFile(filename, trade.ResultRetcodeDescription());
         MarkProcessed(id, "rejected-order");
      }
   }
}

//+------------------------------------------------------------------+
//| JSON string parser                                               |
//+------------------------------------------------------------------+
string JsonString(string json, string key)
{
   string needle = "\"" + key + "\"";
   int p = StringFind(json, needle);
   if(p < 0) return "";
   p = StringFind(json, ":", p + StringLen(needle));
   if(p < 0) return "";
   p++;
   while(p < StringLen(json) && (StringGetCharacter(json, p) == ' ' || StringGetCharacter(json, p) == '\"')) p++;
   int start = p;
   while(p < StringLen(json) && StringGetCharacter(json, p) != '\"' &&
         StringGetCharacter(json, p) != ',' && StringGetCharacter(json, p) != '}') p++;
   return StringSubstr(json, start, p - start);
}

//+------------------------------------------------------------------+
//| JSON number parser                                               |
//+------------------------------------------------------------------+
double JsonNumber(string json, string key)
{
   string needle = "\"" + key + "\"";
   int p = StringFind(json, needle);
   if(p < 0) return 0.0;
   p = StringFind(json, ":", p + StringLen(needle));
   if(p < 0) return 0.0;
   p++;
   while(p < StringLen(json) && StringGetCharacter(json, p) == ' ') p++;
   int start = p;
   while(p < StringLen(json))
   {
      ushort c = StringGetCharacter(json, p);
      if((c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+') p++;
      else break;
   }
   if(p <= start) return 0.0;
   return StringToDouble(StringSubstr(json, start, p - start));
}

//+------------------------------------------------------------------+
//| Gambar satu baris dashboard (label kiri + nilai kanan)           |
//+------------------------------------------------------------------+
void DashRow(int y, string label, string value, color valCol = clrWhite)
{
   string name = g_dashName + "_" + IntegerToString(y);
   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, InpDashX + 10);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, InpDashY + y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, InpDashTextColor);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   ObjectSetString(0, name, OBJPROP_TEXT, label);

   string name2 = g_dashName + "_" + IntegerToString(y) + "_val";
   ObjectDelete(0, name2);
   ObjectCreate(0, name2, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name2, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name2, OBJPROP_XDISTANCE, InpDashX + 130);
   ObjectSetInteger(0, name2, OBJPROP_YDISTANCE, InpDashY + y);
   ObjectSetInteger(0, name2, OBJPROP_COLOR, valCol);
   ObjectSetInteger(0, name2, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, name2, OBJPROP_FONT, "Consolas");
   ObjectSetString(0, name2, OBJPROP_TEXT, value);
}

//+------------------------------------------------------------------+
//| Render dashboard                                                 |
//+------------------------------------------------------------------+
void RenderDashboard()
{
   if(!InpShowDashboard) return;

   //--- Background panel
   string bg = g_dashName + "_bg";
   ObjectDelete(0, bg);
   ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, InpDashX);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, InpDashY);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, InpDashWidth);
   int dashHeight = InpDashShowLog ? 340 : 260;
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, dashHeight);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, InpDashBgColor);
   ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bg, OBJPROP_COLOR, InpDashTitleColor);
   ObjectSetInteger(0, bg, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, bg, OBJPROP_BACK, false);
   ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);

   //--- Title bar
   string title = g_dashName + "_title";
   ObjectDelete(0, title);
   ObjectCreate(0, title, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, title, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, title, OBJPROP_XDISTANCE, InpDashX);
   ObjectSetInteger(0, title, OBJPROP_YDISTANCE, InpDashY);
   ObjectSetInteger(0, title, OBJPROP_XSIZE, InpDashWidth);
   ObjectSetInteger(0, title, OBJPROP_YSIZE, 22);
   ObjectSetInteger(0, title, OBJPROP_BGCOLOR, InpDashTitleColor);
   ObjectSetInteger(0, title, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, title, OBJPROP_COLOR, InpDashTitleColor);
   ObjectSetInteger(0, title, OBJPROP_BACK, false);
   ObjectSetInteger(0, title, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, title, OBJPROP_HIDDEN, true);

   string titleTxt = g_dashName + "_titleTxt";
   ObjectDelete(0, titleTxt);
   ObjectCreate(0, titleTxt, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, titleTxt, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, titleTxt, OBJPROP_XDISTANCE, InpDashX + 10);
   ObjectSetInteger(0, titleTxt, OBJPROP_YDISTANCE, InpDashY + 4);
   ObjectSetInteger(0, titleTxt, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, titleTxt, OBJPROP_FONTSIZE, 10);
   ObjectSetString(0, titleTxt, OBJPROP_FONT, "Arial Bold");
   ObjectSetString(0, titleTxt, OBJPROP_TEXT, "◆ BLACK CUBE BRIDGE EA");

   //--- Status
   int y = 30;
   color stateCol = (g_eaState == "RUNNING") ? InpDashOkColor :
                    (g_eaState == "ERROR") ? InpDashErrColor : InpDashWarnColor;
   DashRow(y, "Status", g_eaState, stateCol);

   y += 18;
   color demoCol = IsDemoAccount() ? InpDashOkColor : InpDashErrColor;
   DashRow(y, "Account", IsDemoAccount() ? "DEMO" : "LIVE", demoCol);

   y += 18;
   DashRow(y, "Symbol", InpSymbol, InpDashTextColor);

   y += 18;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double profit = equity - balance;
   DashRow(y, "Equity", DoubleToString(equity, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY),
           profit >= 0 ? InpDashOkColor : InpDashErrColor);

   y += 18;
   DashRow(y, "Open P/L", DoubleToString(profit, 2),
           profit >= 0 ? InpDashOkColor : InpDashErrColor);

   y += 18;
   DashRow(y, "Open Pos", IntegerToString(CountOurPositions()) + " / " + IntegerToString(InpMaxOpenPositions),
           CountOurPositions() >= InpMaxOpenPositions ? InpDashWarnColor : InpDashTextColor);

   y += 18;
   MqlTick tick;
   SymbolInfoTick(InpSymbol, tick);
   double point = SymbolInfoDouble(InpSymbol, SYMBOL_POINT);
   double spread = (point > 0) ? (tick.ask - tick.bid) / point : 0;
   DashRow(y, "Bid / Ask", DoubleToString(tick.bid, 2) + " / " + DoubleToString(tick.ask, 2),
           InpDashTextColor);

   y += 18;
   DashRow(y, "Spread", DoubleToString(spread, 1) + " pts",
           spread > InpMaxSpreadPoints ? InpDashErrColor : InpDashOkColor);

   y += 18;
   DashRow(y, "Risk %", DoubleToString(InpRiskPercent, 2) + " %", InpDashTextColor);

   y += 22;
   DashRow(y, "Processed", IntegerToString(g_statProcessed), InpDashOkColor);
   y += 16;
   DashRow(y, "Executed", IntegerToString(g_statExecuted), InpDashOkColor);
   y += 16;
   DashRow(y, "Rejected", IntegerToString(g_statRejected), InpDashErrColor);

   //--- Last signal
   if(g_lastSignalId != "")
   {
      y += 22;
      string sigText = g_lastSignalAction + " " + g_lastSignalResult;
      color sigCol = (g_lastSignalResult == "EXECUTED") ? InpDashOkColor :
                     (StringFind(g_lastSignalResult, "rejected") >= 0) ? InpDashErrColor :
                     InpDashWarnColor;
      DashRow(y, "Last Signal", sigText, sigCol);
      y += 16;
      DashRow(y, "Last ID", StringSubstr(g_lastSignalId, 0, 22), InpDashTextColor);
   }

   //--- Log area
   if(InpDashShowLog && g_logCount > 0)
   {
      y += 22;
      string logTitle = g_dashName + "_logTitle";
      ObjectDelete(0, logTitle);
      ObjectCreate(0, logTitle, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, logTitle, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, logTitle, OBJPROP_XDISTANCE, InpDashX + 10);
      ObjectSetInteger(0, logTitle, OBJPROP_YDISTANCE, InpDashY + y);
      ObjectSetInteger(0, logTitle, OBJPROP_COLOR, InpDashTitleColor);
      ObjectSetInteger(0, logTitle, OBJPROP_FONTSIZE, 9);
      ObjectSetString(0, logTitle, OBJPROP_FONT, "Consolas Bold");
      ObjectSetString(0, logTitle, OBJPROP_TEXT, "─ Activity Log ─");

      y += 16;
      int showCount = MathMin(g_logCount, 5);
      for(int i = 0; i < showCount; i++)
      {
         int idx = (g_logScrollIdx - showCount + i + 10) % 10;
         string line = g_logLines[idx];
         if(line == "") continue;
         string logName = g_dashName + "_log" + IntegerToString(i);
         ObjectDelete(0, logName);
         ObjectCreate(0, logName, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, logName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, logName, OBJPROP_XDISTANCE, InpDashX + 10);
         ObjectSetInteger(0, logName, OBJPROP_YDISTANCE, InpDashY + y);
         ObjectSetInteger(0, logName, OBJPROP_COLOR, InpDashTextColor);
         ObjectSetInteger(0, logName, OBJPROP_FONTSIZE, 8);
         ObjectSetString(0, logName, OBJPROP_FONT, "Consolas");
         ObjectSetString(0, logName, OBJPROP_TEXT, StringSubstr(line, 0, 44));
         y += 13;
      }
   }
}

//+------------------------------------------------------------------+
//| Hapus objek dashboard                                            |
//+------------------------------------------------------------------+
void CleanDashboard()
{
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, -1);
      if(StringFind(name, g_dashName) == 0)
         ObjectDelete(0, name);
   }
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpRiskPercent <= 0 || InpRiskPercent > 2.0)
   {
      Print("Safety stop: InpRiskPercent must be > 0 and <= 2.0");
      g_eaState = "ERROR: Risk% invalid";
      return INIT_PARAMETERS_INCORRECT;
   }
   if(!IsDemoAccount() && !InpAllowLiveAccount)
      Print("Live account detected: trading is disabled until InpAllowLiveAccount is explicitly enabled.");
   FolderCreate("BlackCube", FILE_COMMON);
   FolderCreate(QUEUE_DIR, FILE_COMMON);
   FolderCreate(DONE_DIR, FILE_COMMON);
   FolderCreate(FAIL_DIR, FILE_COMMON);
   EventSetTimer(MathMax(1, InpPollSeconds));
   Print("BlackCube Bridge EA ready. Symbol=", InpSymbol,
         " demo=", IsDemoAccount(), " risk%=", InpRiskPercent);

   g_eaState = "RUNNING";
   DashLog("EA initialized", InpDashOkColor);
   RenderDashboard();
   ChartRedraw();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   CleanDashboard();
}

//+------------------------------------------------------------------+
//| OnTimer                                                          |
//+------------------------------------------------------------------+
void OnTimer()
{
   g_lastPollTime = TimeCurrent();

   string filename;
   long search = FileFindFirst(QUEUE_DIR + "\\*.json", filename, FILE_COMMON);
   if(search != INVALID_HANDLE)
   {
      int processedThisPass = 0;
      do
      {
         ProcessFile(filename);
         processedThisPass++;
         if(processedThisPass >= 10) break;
      }
      while(FileFindNext(search, filename));
      FileFindClose(search);
   }

   //--- Cek koneksi
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
      g_eaState = "DISCONNECTED";
   else if(!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      g_eaState = "ALGO OFF";
   else
      g_eaState = "RUNNING";

   RenderDashboard();
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| OnTick (dashboard refresh on price change)                        |
//+------------------------------------------------------------------+
void OnTick()
{
   if(InpShowDashboard)
   {
      RenderDashboard();
      ChartRedraw();
   }
}

//+------------------------------------------------------------------+
//| OnChartEvent (dashboard refresh on chart interaction)           |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_CHART_CHANGE && InpShowDashboard)
      RenderDashboard();
}
//+------------------------------------------------------------------+