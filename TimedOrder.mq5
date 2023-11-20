//+------------------------------------------------------------------+
//|                                                      Timed Order |
//|                                  Copyright © 2023, EarnForex.com |
//|                                       https://www.earnforex.com/ |
//+------------------------------------------------------------------+
#property copyright "Copyright © 2023, EarnForex"
#property link      "https://www.earnforex.com/metatrader-expert-advisors/TimedOrder/"
#property version   "1.01"

#include <Trade/Trade.mqh>

#property description "Opens a trade (market or pending order) at the specified time."
#property description "One-time or daily."

enum ENUM_SLTP_TYPE
{
    SLTP_TYPE_PRICELEVEL, // Price level (might be unfit for a market order)
    SLTP_TYPE_DISTANCE, // Distance from entry in points
    SLTP_TYPE_ATR, // ATR-based with multiplier
    SLTP_TYPE_SPREADS // Number of spreads
};

enum ENUM_TIME_TYPE
{
    TIME_TYPE_LOCAL, // Local time
    TIME_TYPE_SERVER // Server time
};

// Because ENUM_ORDER_TYPE contains ORDER_TYPE_BALANCE and ORDER_TYPE_CREDIT. It is also unsightly.
enum ENUM_BETTER_ORDER_TYPE
{
    BETTER_ORDER_TYPE_BUY, // Buy
    BETTER_ORDER_TYPE_SELL, // Sell
    BETTER_ORDER_TYPE_BUYLIMIT, // Buy Limit
    BETTER_ORDER_TYPE_SELLLIMIT, // Sell Limit
    BETTER_ORDER_TYPE_BUYSTOP, // Buy Stop
    BETTER_ORDER_TYPE_SELLSTOP, // Sell Stop
    BETTER_ORDER_TYPE_BUY_STOP_LIMIT, // Buy Stop Limit
    BETTER_ORDER_TYPE_SELL_STOP_LIMIT // Sell Stop Limit
};

input group "Trading"
input datetime OrderTime = __DATETIME__; // Date/time (server) to open order
input ENUM_BETTER_ORDER_TYPE OrderType = BETTER_ORDER_TYPE_BUY; // Order type
input double Entry = 0; // Entry price (optional)
input int EntryDistancePoints = 0; // Entry distance in points (for pending)
input double StopPrice = 0; // Stop price (for Stop Limit orders)
input ENUM_SLTP_TYPE SLType = SLTP_TYPE_PRICELEVEL; // Stop-loss type
input double StopLoss = 0;
input ENUM_SLTP_TYPE TPType = SLTP_TYPE_PRICELEVEL; // Take-profit type
input double TakeProfit = 0;
input ENUM_TIME_TYPE TimeType = TIME_TYPE_SERVER; // Time type
input group "Control"
input datetime Expires = 0; // Expires on (if pending)
input int Retries = 10; // How many times to try sending order before failure?
input int MaxDifference = 0; // Max difference between given price and market price (points)
input int MaxSpread = 3; // Maximum spread in points
input bool RetryUntilMaxSpread = false; // Retry until spread falls below MaxSpread?
input int Slippage = 30; // Maximum slippage in points
input ENUM_TIMEFRAMES ATR_Timeframe = PERIOD_CURRENT; // ATR Timeframe
input int ATR_Period = 14; // ATR Period
input group "Daily mode"
input bool DailyMode = false; // Daily mode: if true, will trade every given day.
input string DailyTime = "18:34:00"; // Time for daily trades in HH:MM:SS format.
input bool Monday = true;
input bool Tuesday = true;
input bool Wednesday = true;
input bool Thursday = true;
input bool Friday = true;
input bool Saturday = false;
input bool Sunday = false;
input group "Position sizing"
input bool CalculatePositionSize = false; // CalculatePositionSize: Use money management module?
input double FixedPositionSize = 0.01; // FixedPositionSize: Used if CalculatePositionSize = false.
input double Risk = 1; // Risk: Risk tolerance in percentage points.
input double MoneyRisk = 0; // MoneyRisk: Risk tolerance in base currency.
input bool UseMoneyInsteadOfPercentage = false;
input bool UseEquityInsteadOfBalance = false;
input double FixedBalance = 0; // FixedBalance: If > 0, trade size calc. uses it as balance.
input group "Alerts"
input bool AlertsOnSuccess = false; // Alert on success?
input bool AlertsOnFailure = false; // Alert on failure?
input bool EnableNativeAlerts = false; // Enable native alerts
input bool EnableEmailAlerts = false; // Enable email alerts
input bool EnablePushAlerts = false; // Enable push-notification alerts
input group "Miscellaneous"
input int Magic = 20220913;
input string OrderCommentary = "TimedOrder";
input bool Silent = false; // Silent: If true, does not display any output via chart comment.
input bool Logging = true; // Logging: If true, errors will be logged to a file.

// Global variables:
bool CanWork;
bool WillNoLongerTryOpeningTrade;
bool Terminal_Trade_Allowed = true;
string PostOrderText;
long global_ticket = 0;
ENUM_ORDER_TYPE TradeType;
int last_error;
int ATR_handle;
bool EnabledDays[7]; // For Daily Mode.

// For tick value adjustment:
string AccountCurrency = "";
string ProfitCurrency = "";
string BaseCurrency = "";
ENUM_SYMBOL_CALC_MODE CalcMode;
string ReferencePair = NULL;
bool ReferenceSymbolMode;

// Main trading objects:
CTrade *Trade;

// For error logging:
string filename;

int OnInit()
{
    ResetVariables();
    
    TradeType = (ENUM_ORDER_TYPE)OrderType;
    
    if (Logging)
    {
        MqlDateTime dt;
        TimeToStruct(TimeLocal(), dt);
        filename = "TO-Log-" + Symbol() + IntegerToString(dt.year) + IntegerToString(dt.mon, 2, '0') + IntegerToString(dt.day, 2, '0') + IntegerToString(dt.hour, 2, '0') + IntegerToString(dt.min, 2, '0') + IntegerToString(dt.sec, 2, '0');
        StringReplace(filename, ".", "_"); // Avoid potential extra dot from the symbol name.
        filename += ".log";
    }
    
    string Error = CheckInputParameters();
    if (Error != "")
    {
        if (!Silent) Comment("Wrong input parameters!\n" + Error);
        Output("Wrong input parameters! " + Error);
        CanWork = false;
        return INIT_SUCCEEDED;
        //return INIT_FAILED; // Bad idea because it will wipe all the input parameters entered by the users.
    }
    
    EnabledDays[0] = Sunday;
    EnabledDays[1] = Monday;
    EnabledDays[2] = Tuesday;
    EnabledDays[3] = Wednesday;
    EnabledDays[4] = Thursday;
    EnabledDays[5] = Friday;
    EnabledDays[6] = Saturday;
    
    EventSetMillisecondTimer(100);

    Trade = new CTrade;
    Trade.SetDeviationInPoints(Slippage);
    Trade.SetExpertMagicNumber(Magic);
    
    if ((SLType == SLTP_TYPE_ATR) || (TPType == SLTP_TYPE_ATR))
    {
        ATR_handle = iATR(Symbol(), ATR_Timeframe, ATR_Period);
    }
    
    CanWork = true;
    WillNoLongerTryOpeningTrade = false;
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    delete Trade;
    if (!Silent) Comment("");
}

void OnTick()
{
    if (!CanWork) return; // Don't operate if there was some initialization problem.
    if (!Silent) ShowStatus();
    if (!WillNoLongerTryOpeningTrade) DoTrading();
}

void OnTimer()
{
    if (!CanWork) return; // Don't operate if there was some initialization problem.
    if (!Silent) ShowStatus();
    if (!WillNoLongerTryOpeningTrade) DoTrading();
}

//+------------------------------------------------------------------+
//| Calculates unit cost based on profit calculation mode.           |
//+------------------------------------------------------------------+
double CalculateUnitCost()
{
    double UnitCost;
    // CFD.
    if (((CalcMode == SYMBOL_CALC_MODE_CFD) || (CalcMode == SYMBOL_CALC_MODE_CFDINDEX) || (CalcMode == SYMBOL_CALC_MODE_CFDLEVERAGE)))
        UnitCost = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE) * SymbolInfoDouble(Symbol(), SYMBOL_TRADE_CONTRACT_SIZE);
    // With Forex and futures instruments, tick value already equals 1 unit cost.
    else UnitCost = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE_LOSS);
    
    return UnitCost;
}

//+-----------------------------------------------------------------------------------+
//| Calculates necessary adjustments for cases when GivenCurrency != AccountCurrency. |
//+-----------------------------------------------------------------------------------+
double CalculateAdjustment()
{
    if (ReferencePair == NULL)
    {
        ReferencePair = GetSymbolByCurrencies(ProfitCurrency, AccountCurrency);
        ReferenceSymbolMode = true;
        // Failed.
        if (ReferencePair == NULL)
        {
            // Reversing currencies.
            ReferencePair = GetSymbolByCurrencies(AccountCurrency, ProfitCurrency);
            ReferenceSymbolMode = false;
        }
    }
    if (ReferencePair == NULL)
    {
        Print("Error! Cannot detect proper currency pair for adjustment calculation: ", ProfitCurrency, ", ", AccountCurrency, ".");
        ReferencePair = Symbol();
        return 1;
    }
    MqlTick tick;
    SymbolInfoTick(ReferencePair, tick);
    return GetCurrencyCorrectionCoefficient(tick);
}

//+---------------------------------------------------------------------------+
//| Returns a currency pair with specified base currency and profit currency. |
//+---------------------------------------------------------------------------+
string GetSymbolByCurrencies(string base_currency, string profit_currency)
{
    // Cycle through all symbols.
    for (int s = 0; s < SymbolsTotal(false); s++)
    {
        // Get symbol name by number.
        string symbolname = SymbolName(s, false);

        // Skip non-Forex pairs.
        if ((SymbolInfoInteger(symbolname, SYMBOL_TRADE_CALC_MODE) != SYMBOL_CALC_MODE_FOREX) && (SymbolInfoInteger(symbolname, SYMBOL_TRADE_CALC_MODE) != SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE)) continue;

        // Get its base currency.
        string b_cur = SymbolInfoString(symbolname, SYMBOL_CURRENCY_BASE);
        if (b_cur == "RUR") b_cur = "RUB";

        // Get its profit currency.
        string p_cur = SymbolInfoString(symbolname, SYMBOL_CURRENCY_PROFIT);
        if (p_cur == "RUR") p_cur = "RUB";

        // If the currency pair matches both currencies, select it in Market Watch and return its name.
        if ((b_cur == base_currency) && (p_cur == profit_currency))
        {
            // Select if necessary.
            if (!(bool)SymbolInfoInteger(symbolname, SYMBOL_SELECT)) SymbolSelect(symbolname, true);

            return symbolname;
        }
    }
    return NULL;
}

//+------------------------------------------------------------------+
//| Get correction coefficient based on currency, trade direction,   |
//| and current prices.                                              |
//+------------------------------------------------------------------+
double GetCurrencyCorrectionCoefficient(MqlTick &tick)
{
    if ((tick.ask == 0) || (tick.bid == 0)) return -1; // Data is not yet ready.
    // Reverse quote.
    if (ReferenceSymbolMode)
    {
        // Using Buy price for reverse quote.
        return tick.ask;
    }
    // Direct quote.
    else
    {
        // Using Sell price for direct quote.
        return (1 / tick.bid);
    }
}

// Taken from the PositionSizeCalculator indicator.
double GetPositionSize(double entry, double stoploss, ENUM_ORDER_TYPE dir)
{
    double Size, RiskMoney, PositionSize = 0;

    double SL = MathAbs(entry - stoploss);

    AccountCurrency = AccountInfoString(ACCOUNT_CURRENCY);

    // A rough patch for cases when account currency is set as RUR instead of RUB.
    if (AccountCurrency == "RUR") AccountCurrency = "RUB";

    ProfitCurrency = SymbolInfoString(Symbol(), SYMBOL_CURRENCY_PROFIT);
    if (ProfitCurrency == "RUR") ProfitCurrency = "RUB";
    BaseCurrency = SymbolInfoString(Symbol(), SYMBOL_CURRENCY_BASE);
    if (BaseCurrency == "RUR") BaseCurrency = "RUB";
    CalcMode = (ENUM_SYMBOL_CALC_MODE)SymbolInfoInteger(Symbol(), SYMBOL_TRADE_CALC_MODE);
    double LotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    int LotStep_digits = CountDecimalPlaces(LotStep);

    if (!CalculatePositionSize) return(FixedPositionSize);

    // If could not find account currency, probably not connected.
    if (AccountInfoString(ACCOUNT_CURRENCY) == "") return -1;

    if (FixedBalance > 0)
    {
        Size = FixedBalance;
    }
    else if (UseEquityInsteadOfBalance)
    {
        Size = AccountInfoDouble(ACCOUNT_EQUITY);
    }
    else
    {
        Size = AccountInfoDouble(ACCOUNT_BALANCE);
    }

    if (!UseMoneyInsteadOfPercentage) RiskMoney = Size * Risk / 100;
    else RiskMoney = MoneyRisk;

    double UnitCost = CalculateUnitCost();

    // If profit currency is different from account currency and Symbol is not a Forex pair or futures (CFD, and so on).
    if ((ProfitCurrency != AccountCurrency) && (CalcMode != SYMBOL_CALC_MODE_FOREX) && (CalcMode != SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE) && (CalcMode != SYMBOL_CALC_MODE_FUTURES) && (CalcMode != SYMBOL_CALC_MODE_EXCH_FUTURES) && (CalcMode != SYMBOL_CALC_MODE_EXCH_FUTURES_FORTS))
    {
        double CCC = CalculateAdjustment(); // Valid only for loss calculation.
        // Adjust the unit cost.
        UnitCost *= CCC;
    }

    // If account currency == pair's base currency, adjust UnitCost to future rate (SL). Works only for Forex pairs.
    if ((AccountCurrency == BaseCurrency) && ((CalcMode == SYMBOL_CALC_MODE_FOREX) || (CalcMode == SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE)))
    {
        double current_rate = 1, future_rate = stoploss;
        if (dir == ORDER_TYPE_BUY)
        {
            current_rate = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        }
        else if (dir == ORDER_TYPE_SELL)
        {
            current_rate = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        }
        UnitCost *= (current_rate / future_rate);
    }

    double TickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if ((SL != 0) && (UnitCost != 0) && (TickSize != 0)) PositionSize = NormalizeDouble(RiskMoney / (SL * UnitCost / TickSize), LotStep_digits);

    if (PositionSize < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)) PositionSize = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    else if (PositionSize > SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX)) PositionSize = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double steps = PositionSize / SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    if (MathFloor(steps) < steps) PositionSize = MathFloor(steps) * SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    return PositionSize;
}

// Prints and writes to file error info and context data.
void Output(string s)
{
    Print(s);
    if (!Logging) return;
    int file = FileOpen(filename, FILE_CSV | FILE_READ | FILE_WRITE);
    if (file == -1) Print("Failed to create an error log file: ", GetLastError(), ".");
    else
    {
        FileSeek(file, 0, SEEK_END);
        s = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + " - " + s;
        FileWrite(file, s);
        FileClose(file);
    }
}

//+------------------------------------------------------------------+
//| Counts decimal places.                                           |
//+------------------------------------------------------------------+
int CountDecimalPlaces(double number)
{
    // 100 as maximum length of number.
    for (int i = 0; i < 100; i++)
    {
        double pwr = MathPow(10, i);
        if (MathRound(number * pwr) / pwr == number) return i;
    }
    return -1;
}

//+------------------------------------------------------------------+
//| Main execution procedure.                                        |
//+------------------------------------------------------------------+
void DoTrading()
{
    if ((TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) == false) || (!CanWork))
    {
        if ((TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) == false) && (Terminal_Trade_Allowed == true))
        {
            Output("Trading not allowed.");
            Terminal_Trade_Allowed = false;
        }
        else if ((TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) == true) && (Terminal_Trade_Allowed == false))
        {
            Output("Trading allowed.");
            Terminal_Trade_Allowed = true;
        }
        return;
    }

    // Do nothing if it is too early.
    datetime current_time;
    if (TimeType == TIME_TYPE_SERVER) current_time = TimeCurrent();
    else current_time = TimeLocal();
								 

    datetime order_time = OrderTime;
    if (DailyMode) order_time = GetOrderTimeForDailyMode(current_time);
    if (current_time < order_time) return;

    // Time is due. At this point, if something fails, the EA won't try again until it is reloaded.
    WillNoLongerTryOpeningTrade = true;

    double SL = 0, TP = 0;

    if (SLType == SLTP_TYPE_ATR)
    {
        double ATR[];
        while (CopyBuffer(ATR_handle, 0, 0, 1, ATR) != 1) return;
        SL = ATR[0] * StopLoss;
    }
    else if (SLType == SLTP_TYPE_SPREADS) SL = SymbolInfoInteger(Symbol(), SYMBOL_SPREAD) * StopLoss * Point();
    else if (SLType == SLTP_TYPE_DISTANCE) SL = StopLoss * Point();
    else SL = StopLoss; // Level.

    if (TPType == SLTP_TYPE_ATR)
    {
        double ATR[];
        while (CopyBuffer(ATR_handle, 0, 0, 1, ATR) != 1) return;
        TP = ATR[0] * TakeProfit;
    }
    else if (TPType == SLTP_TYPE_SPREADS) TP = SymbolInfoInteger(Symbol(), SYMBOL_SPREAD) * TakeProfit * Point();
    else if (TPType == SLTP_TYPE_DISTANCE) TP = TakeProfit * Point();
    else TP = TakeProfit; // Level.

    // Prevent position opening when the spread is too wide (greater than MaxSpread input).
    int spread = (int)SymbolInfoInteger(Symbol(), SYMBOL_SPREAD);
    if ((MaxSpread > 0) && (spread > MaxSpread))
    {
        string explanation = "Current spread " + IntegerToString(spread) + " > maximum spread " + IntegerToString(MaxSpread) + ". Not opening the trade.";
        if (RetryUntilMaxSpread) explanation += " Waiting for spread to go below the MaxSpread setting.";
        Output(explanation);
        if (RetryUntilMaxSpread)
        {
            WillNoLongerTryOpeningTrade = false; // Let it try again.
            return;
        }

        if (AlertsOnFailure)
        {
            string NativeText = OrderToString(TradeType) + ". " + explanation;
            string Text = Symbol() + " @ " + StringSubstr(EnumToString((ENUM_TIMEFRAMES)Period()), 7) + " - " + NativeText;
            if (EnableNativeAlerts) Alert(NativeText);
            if (EnableEmailAlerts) SendMail("Timed Order Alert - " + Symbol() + " @ " + StringSubstr(EnumToString((ENUM_TIMEFRAMES)Period()), 7), Text);
            if (EnablePushAlerts) SendNotification(Text);
        }
        global_ticket = -1;
        return;
    }

    long ticket = 0;
    ENUM_ORDER_TYPE order_type = TradeType; // Might get updated in pending mode. Should be reflected in the alerts.
    if ((TradeType == ORDER_TYPE_BUY) || (TradeType == ORDER_TYPE_SELL)) // Market
    {
        double price = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
        if (TradeType == ORDER_TYPE_SELL) price = SymbolInfoDouble(Symbol(), SYMBOL_BID);
        if ((SLType != SLTP_TYPE_PRICELEVEL) && (SL != 0))
        {
            // Get SL as price level.
            if (TradeType == ORDER_TYPE_BUY) SL = price - SL;
            else if (TradeType == ORDER_TYPE_SELL) SL = price + SL;
        }
        if ((TPType != SLTP_TYPE_PRICELEVEL) && (TP != 0))
        {
            // Get TP as price level.
            if (TradeType == ORDER_TYPE_BUY) TP = price + TP;
            else if (TradeType == ORDER_TYPE_SELL) TP = price - TP;
        }
        if ((MaxDifference > 0) && (MathAbs(Entry - price) > MaxDifference * Point()))
        {
            string explanation = "Price difference " + DoubleToString(MathAbs(Entry - price), _Digits) + " > maximum price difference " + DoubleToString((double)MaxDifference * Point(), _Digits) + ". Not opening the trade.";
            Output(explanation);
            if (AlertsOnFailure)
            {
                string NativeText = OrderToString(TradeType) + ". " + explanation;
                string Text = Symbol() + " @ " + StringSubstr(EnumToString((ENUM_TIMEFRAMES)Period()), 7) + " - " + NativeText;
                if (EnableNativeAlerts) Alert(NativeText);
                if (EnableEmailAlerts) SendMail("Timed Order Alert - " + Symbol() + " @ " + StringSubstr(EnumToString((ENUM_TIMEFRAMES)Period()), 7), Text);
                if (EnablePushAlerts) SendNotification(Text);
            }
            global_ticket = -1;
            return;
        }
        ticket = ExecuteMarketOrder(TradeType, GetPositionSize(price, SL, TradeType), price, SL, TP);

        double LotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
        int LotStep_digits = CountDecimalPlaces(LotStep);
        if (!PositionSelectByTicket(ticket))
        {
            PostOrderText = "Failed to select position: " + IntegerToString(GetLastError());
            Output(PostOrderText);
        }
        else
        {
            PostOrderText = DoubleToString(PositionGetDouble(POSITION_VOLUME), LotStep_digits) + " lots; Open = " + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), _Digits);
            if (SL != 0) PostOrderText += " SL = " + DoubleToString(PositionGetDouble(POSITION_SL), _Digits);
            if (TP != 0) PostOrderText += " TP = " + DoubleToString(PositionGetDouble(POSITION_TP), _Digits);
        }
    }
    else // Pending
    {
        // Modify trade type based on the current price.
        double price = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
        double entry = Entry;
        if ((TradeType == ORDER_TYPE_SELL_STOP) || (TradeType == ORDER_TYPE_SELL_LIMIT) || (TradeType == ORDER_TYPE_SELL_STOP_LIMIT)) price = SymbolInfoDouble(Symbol(), SYMBOL_BID);
        if ((EntryDistancePoints > 0) && (TradeType != ORDER_TYPE_BUY_STOP_LIMIT) && (TradeType != ORDER_TYPE_SELL_STOP_LIMIT)) // Doesn't work with Stop Limit orders.
        {
            // order_type remains being equal TradeType.
            if ((order_type == ORDER_TYPE_BUY_STOP) || (order_type == ORDER_TYPE_SELL_LIMIT)) entry = price + EntryDistancePoints * _Point;
            else if ((order_type == ORDER_TYPE_SELL_STOP) || (order_type == ORDER_TYPE_BUY_LIMIT)) entry = price - EntryDistancePoints * _Point;
        }
        else
        {
            if ((TradeType == ORDER_TYPE_BUY_STOP) && (Entry < price)) order_type = ORDER_TYPE_BUY_LIMIT;
            else if ((TradeType == ORDER_TYPE_BUY_LIMIT) && (Entry > price)) order_type = ORDER_TYPE_BUY_STOP;
            else if ((TradeType == ORDER_TYPE_SELL_STOP) && (Entry > price)) order_type = ORDER_TYPE_SELL_LIMIT;
            else if ((TradeType == ORDER_TYPE_SELL_LIMIT) && (Entry < price)) order_type = ORDER_TYPE_SELL_STOP;
        }
        if ((TradeType == ORDER_TYPE_BUY_STOP_LIMIT) && (StopPrice < price)) order_type = ORDER_TYPE_SELL_STOP_LIMIT;
        else if ((TradeType == ORDER_TYPE_SELL_STOP_LIMIT) && (StopPrice > price)) order_type = ORDER_TYPE_BUY_STOP_LIMIT;
                
        if ((SLType != SLTP_TYPE_PRICELEVEL) && (SL != 0))
        {
            // Get SL as price level.
            if ((order_type == ORDER_TYPE_BUY_STOP) || (order_type == ORDER_TYPE_BUY_LIMIT) || (order_type == ORDER_TYPE_BUY_STOP_LIMIT)) SL = entry - SL;
            else if ((order_type == ORDER_TYPE_SELL_STOP) || (order_type == ORDER_TYPE_SELL_LIMIT) || (order_type == ORDER_TYPE_SELL_STOP_LIMIT)) SL = entry + SL;
        }
        if ((TPType != SLTP_TYPE_PRICELEVEL) && (TP != 0))
        {
            // Get TP as price level.
            if ((order_type == ORDER_TYPE_BUY_STOP) || (order_type == ORDER_TYPE_BUY_LIMIT) || (order_type == ORDER_TYPE_BUY_STOP_LIMIT)) TP = entry + TP;
            else if ((order_type == ORDER_TYPE_SELL_STOP) || (order_type == ORDER_TYPE_SELL_LIMIT) || (order_type == ORDER_TYPE_SELL_STOP_LIMIT)) TP = entry - TP;
        }
        // For position size calculation.
        ENUM_ORDER_TYPE dir = ORDER_TYPE_BUY;
        if ((order_type == ORDER_TYPE_SELL_LIMIT) || (order_type == ORDER_TYPE_SELL_STOP) || (order_type == ORDER_TYPE_SELL_STOP_LIMIT)) dir = ORDER_TYPE_SELL;
        ticket = CreatePendingOrder(order_type, GetPositionSize(entry, SL, dir), entry, SL, TP);

        double LotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
        int LotStep_digits = CountDecimalPlaces(LotStep);
        if (!OrderSelect(ticket))
        {
            PostOrderText = "Failed to select order: " + IntegerToString(GetLastError());
            Output(PostOrderText);
        }
        else
        {
            PostOrderText = DoubleToString(OrderGetDouble(ORDER_VOLUME_CURRENT), LotStep_digits) + " lots; Open = " + DoubleToString(OrderGetDouble(ORDER_PRICE_OPEN), _Digits);
            if (SL != 0) PostOrderText += " SL = " + DoubleToString(OrderGetDouble(ORDER_SL), _Digits);
            if (TP != 0) PostOrderText += " TP = " + DoubleToString(OrderGetDouble(ORDER_TP), _Digits);
            if ((order_type == ORDER_TYPE_BUY_STOP_LIMIT) || (order_type == ORDER_TYPE_SELL_STOP_LIMIT)) PostOrderText += " StopPrice = " + DoubleToString(OrderGetDouble(ORDER_PRICE_STOPLIMIT), _Digits);
            if (OrderGetInteger(ORDER_TIME_EXPIRATION) > 0) PostOrderText += " Expiration = " + TimeToString(OrderGetInteger(ORDER_TIME_EXPIRATION));
        }
    }

    if (ticket > 0)
    {
        global_ticket = ticket;

        if (AlertsOnSuccess)
        {
            string NativeText = OrderToString(order_type) + ". Created: " + PostOrderText;
            string Text = Symbol() + " @ " + StringSubstr(EnumToString((ENUM_TIMEFRAMES)Period()), 7) + " - " + NativeText;
            if (EnableNativeAlerts) Alert(NativeText);
            if (EnableEmailAlerts) SendMail("Timed Order Alert - " + Symbol() + " @ " + StringSubstr(EnumToString((ENUM_TIMEFRAMES)Period()), 7), Text);
            if (EnablePushAlerts) SendNotification(Text);
        }
    }
    else
    {
        if (AlertsOnFailure)
        {
            string NativeText = OrderToString(order_type) + ". Failed after " + IntegerToString(Retries) + " tries: " + IntegerToString(last_error);
            string Text = Symbol() + " @ " + StringSubstr(EnumToString((ENUM_TIMEFRAMES)Period()), 7) + " - " + NativeText;
            if (EnableNativeAlerts) Alert(NativeText);
            if (EnableEmailAlerts) SendMail("Timed Order Alert - " + Symbol() + " @ " + StringSubstr(EnumToString((ENUM_TIMEFRAMES)Period()), 7), Text);
            if (EnablePushAlerts) SendNotification(Text);
        }
    }
}

//+------------------------------------------------------------------+
//| Execute a market order.                                          |
//+------------------------------------------------------------------+
long ExecuteMarketOrder(const int order_type, const double volume, const double price, const double sl, const double tp)
{
    double LotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
    int LotStep_digits = CountDecimalPlaces(LotStep);
    long ticket = -1;
    for (int i = 0; i < Retries; i++)
    {
        if (!Trade.PositionOpen(Symbol(), (ENUM_ORDER_TYPE)order_type, NormalizeDouble(volume, LotStep_digits), NormalizeDouble(price, _Digits), NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), OrderCommentary))
        {
            Output("Error sending order: " + Trade.ResultRetcodeDescription() + ".");
        }
        else
        {
            MqlTradeResult result;
            Trade.Result(result);
            if ((Trade.ResultRetcode() != 10008) && (Trade.ResultRetcode() != 10009) && (Trade.ResultRetcode() != 10010))
            {
                Output("Error opening a position. Return code: " + Trade.ResultRetcodeDescription());
            }
            else
            {
                Output("Initial return code: " + Trade.ResultRetcodeDescription());
    
                ulong order = result.order;
                Output("Order ID: " + IntegerToString(order));
    
                ulong deal = result.deal;
                Output("Deal ID: " + IntegerToString(deal));
    
                // Not all brokers return deal.
                if (deal != 0)
                {
                    if (HistorySelect(TimeCurrent() - 60, TimeCurrent()))
                    {
                        if (HistoryDealSelect(deal))
                        {
                            long position = HistoryDealGetInteger(deal, DEAL_POSITION_ID);
                            Output("Position ID: " + IntegerToString(position));
                            ticket = position;
                        }
                        else
                        {
                            int error = GetLastError();
                            Output("Error selecting deal: " + IntegerToString(error));
                        }
                    }
                    else
                    {
                        int error = GetLastError();
                        Output("Error selecting deal history: " + IntegerToString(error));
                    }
                }
                // Wait for position to open then find it using the order ID.
                else
                {
                    // Run a waiting cycle until the order becomes a positoin.
                    for (int j = 0; j < 10; j++)
                    {
                        Output("Waiting...");
                        Sleep(1000);
                        if (PositionSelectByTicket(order)) break;
                    }
                    if (!PositionSelectByTicket(order))
                    {
                        int error = GetLastError();
                        Output("Error selecting positions: " + IntegerToString(error));
                    }
                    else
                    {
                        ticket = (long)order;
                    }
                }
            }
        }

        if (ticket == -1)
        {
            last_error = GetLastError();
            string order_string = OrderToString((ENUM_ORDER_TYPE)order_type);
            int StopLevel = (int)SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL);

            Output("Error Sending " + order_string + ": " + IntegerToString(last_error));
            Output("Volume = " + DoubleToString(volume, LotStep_digits) + " Entry = " + DoubleToString(price, _Digits) + " SL = " + DoubleToString(sl, _Digits) + " TP = " + DoubleToString(tp, _Digits));
        }
        else
        {
            Output("Order executed. Position: " + IntegerToString(ticket) + ".");
            break;
        }
    }
    
    if (ticket == -1)
    {
        Output("Execution failed after " + IntegerToString(Retries) + " tries.");
    }

    return ticket;
}

//+------------------------------------------------------------------+
//| Create a pending order.                                          |
//+------------------------------------------------------------------+
long CreatePendingOrder(const int order_type, const double volume, const double price, const double sl, const double tp)
{
    double LotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
    int LotStep_digits = CountDecimalPlaces(LotStep);
    long ticket = -1;
    for (int i = 0; i < Retries; i++)
    {
        ENUM_ORDER_TYPE_TIME ott = ORDER_TIME_GTC;
        if (Expires > 0) ott = ORDER_TIME_SPECIFIED;

        if (!Trade.OrderOpen(Symbol(), (ENUM_ORDER_TYPE)order_type, NormalizeDouble(volume, LotStep_digits), ((order_type == ORDER_TYPE_BUY_STOP_LIMIT) || (order_type == ORDER_TYPE_SELL_STOP_LIMIT)) ? NormalizeDouble(price, _Digits) : 0, ((order_type == ORDER_TYPE_BUY_STOP_LIMIT) || (order_type == ORDER_TYPE_SELL_STOP_LIMIT)) ? NormalizeDouble(StopPrice, _Digits) : NormalizeDouble(price, _Digits), NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), ott, Expires, OrderCommentary))
        {
            string order_string = OrderToString((ENUM_ORDER_TYPE)order_type);
            int StopLevel = (int)SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL);
            Output("Error Sending " + order_string + ": " + Trade.ResultRetcodeDescription());
            Output("Volume = " + DoubleToString(volume, LotStep_digits) + " Entry = " + DoubleToString(price, _Digits) + " SL = " + DoubleToString(sl, _Digits) + " TP = " + DoubleToString(tp, _Digits) + " StopLevel = " + IntegerToString(StopLevel));
        }
        else
        {
            ticket = (long)Trade.ResultOrder();
            Output("Order created. Ticket: " + IntegerToString(ticket));
            break;
        }
    }
    
    if (ticket == -1)
    {
        Output("Creation failed after " + IntegerToString(Retries) + " tries.");
    }

    return ticket;
}

// Checks whether input parameters make sense and returns error if they don't.
string CheckInputParameters()
{
    if (!DailyMode) // Normal mode (one-time fixed-date trade).
    {
        // Order time has already passed.
        if (((TimeType == TIME_TYPE_SERVER) && (OrderTime <= TimeCurrent())) ||
            ((TimeType == TIME_TYPE_LOCAL) && (OrderTime <= TimeLocal()))) return "Order time has already passed.";
    }
    else // Daily mode (trades every set day at a given time).
    {
        if (!CheckTime(DailyTime)) return "DailyTime should be in correct HH:MM:SS format.";
        if ((!Monday) && (!Tuesday) && (!Wednesday) && (!Thursday) && (!Friday) && (!Saturday) && (!Sunday)) return "At least one day of the week should be selected.";
    }

    // Pending order with zero entry.
    if ((TradeType != ORDER_TYPE_BUY) && (TradeType != ORDER_TYPE_SELL) && (Entry == 0) && (EntryDistancePoints <= 0)) return "Entry price and distance cannot be both zero for pending orders.";

    // Stop limit order with zero Stop price.
    if ((TradeType == ORDER_TYPE_BUY_STOP_LIMIT) && (TradeType == ORDER_TYPE_SELL_STOP_LIMIT) && (StopPrice == 0)) return "Stop price cannot be zero for Stop Limit orders.";
    
    // SL on the wrong side.
    if ((StopLoss != 0) && (SLType == SLTP_TYPE_PRICELEVEL) && (EntryDistancePoints <= 0))
    {
        if (StopLoss >= Entry)
        {
            if (TradeType == ORDER_TYPE_BUY_STOP) return "Stop-loss cannot be above entry for a Buy Stop.";
            if (TradeType == ORDER_TYPE_BUY_LIMIT) return "Stop-loss cannot be above entry for a Buy Limit.";
        }
        if (StopLoss <= Entry)
        {
            if (TradeType == ORDER_TYPE_SELL_STOP) return "Stop-loss cannot be below entry for a Sell Stop.";
            if (TradeType == ORDER_TYPE_SELL_LIMIT) return "Stop-loss cannot be below entry for a Sell Limit.";
        }
    }
    if ((TakeProfit != 0) && (TPType == SLTP_TYPE_PRICELEVEL) && (EntryDistancePoints <= 0))
    {
        if (TakeProfit <= Entry)
        {
            if (TradeType == ORDER_TYPE_BUY_STOP) return "Take-profit cannot be below entry for a Buy Stop.";
            if (TradeType == ORDER_TYPE_BUY_LIMIT) return "Take-profit cannot be below entry for a Buy Limit.";
        }
        if (TakeProfit >= Entry)
        {
            if (TradeType == ORDER_TYPE_SELL_STOP) return "Take-profit cannot be above entry for a Sell Stop.";
            if (TradeType == ORDER_TYPE_SELL_LIMIT) return "Take-profit cannot be above entry for a Sell Limit.";
        }
    }
    
    if (!CalculatePositionSize)
    {
        if (FixedPositionSize < SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN)) return "Position size " + DoubleToString(FixedPositionSize, CountDecimalPlaces(FixedPositionSize)) + " < minimum volume " + DoubleToString(SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN), CountDecimalPlaces(SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN)));
        if (FixedPositionSize > SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX)) return "Position size " + DoubleToString(FixedPositionSize, CountDecimalPlaces(FixedPositionSize)) + " > maximum volume " + DoubleToString(SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX), CountDecimalPlaces(SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX)));
        double steps = FixedPositionSize / SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
        if (MathFloor(steps) < steps) return "Position size " + DoubleToString(FixedPositionSize, CountDecimalPlaces(FixedPositionSize)) + " is not a multiple of lot step " + DoubleToString(SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP), CountDecimalPlaces(SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP)));
    }
    else
    {
        if (StopLoss == 0) return "Cannot calculate position size based on zero stop-loss.";
    }
    
    if ((Expires > 0) && (Expires < OrderTime)) return "Expiration cannot be earlier than order time.";

    if (Retries < 1) return "Retries cannot be < 1.";

    if (MaxDifference < 0) return "MaxDifference cannot be negative.";
    if (MaxSpread < 0) return "MaxSpread cannot be negative.";
    if (Slippage < 0) return "Slippage cannot be negative.";
    if (ATR_Period < 0) return "ATR_Period cannot be negative.";
        
    return "";
}

void ResetVariables()
{
    ProfitCurrency = "";
    AccountCurrency = "";
    BaseCurrency = "";
    ReferencePair = NULL;
    last_error = 0;
    global_ticket = 0;
    PostOrderText = "";
    WillNoLongerTryOpeningTrade = false;
    CanWork = false;
    Terminal_Trade_Allowed = false;
}

// Display various useful information in the chart comment.
void ShowStatus()
{
    string s = "Timed Order EA\n";

    s += OrderToString(TradeType);

    if ((TradeType == ORDER_TYPE_BUY_STOP) || (TradeType == ORDER_TYPE_BUY_LIMIT) || (TradeType == ORDER_TYPE_SELL_STOP) || (TradeType == ORDER_TYPE_SELL_LIMIT))
    {
        if (EntryDistancePoints <= 0) s += " @ " + DoubleToString(Entry, _Digits);
        else s += " @ " + IntegerToString(EntryDistancePoints) + " pts.";
    }
    else if ((TradeType == ORDER_TYPE_BUY_STOP_LIMIT) || (TradeType == ORDER_TYPE_SELL_STOP_LIMIT))
    {
        s += " @ " + DoubleToString(Entry, _Digits);
    }
    if ((TradeType == ORDER_TYPE_BUY_STOP_LIMIT) || (TradeType == ORDER_TYPE_SELL_STOP_LIMIT)) s += " via " + DoubleToString(StopPrice, _Digits);
    
    if ((!DailyMode) && (global_ticket != 0)) // Order already executed or tried to execute.
    {
        s += "\n";
    
        if (global_ticket > 0)
        {
            s += PostOrderText;
        }
        else s += "Execution failed!";
    }
    else
    {
        s += "\n";
        
        if (SLType == SLTP_TYPE_PRICELEVEL) s += "SL = " + DoubleToString(StopLoss, _Digits);
        else if (SLType == SLTP_TYPE_DISTANCE) s += "SL = " + IntegerToString((int)StopLoss) + " pts.";
        else if (SLType == SLTP_TYPE_ATR) s += "SL = " + DoubleToString(StopLoss, CountDecimalPlaces(StopLoss)) + " x ATR(" + IntegerToString(ATR_Period) + ") @ " + EnumToString(ATR_Timeframe);
        else if (SLType == SLTP_TYPE_SPREADS) s += "SL = " + DoubleToString(StopLoss, CountDecimalPlaces(StopLoss)) + " spreads";
        
        s += "\n";
        
        if (TPType == SLTP_TYPE_PRICELEVEL) s += "TP = " + DoubleToString(TakeProfit, _Digits);
        else if (TPType == SLTP_TYPE_DISTANCE) s += "TP = " + IntegerToString((int)TakeProfit) + " pts.";
        else if (TPType == SLTP_TYPE_ATR) s += "TP = " + DoubleToString(TakeProfit, CountDecimalPlaces(TakeProfit)) + " x ATR(" + IntegerToString(ATR_Period) + ") @ " + EnumToString(ATR_Timeframe);
        else if (TPType == SLTP_TYPE_SPREADS) s += "TP = " + DoubleToString(TakeProfit, CountDecimalPlaces(TakeProfit)) + " spreads";
    
        s += "\n";
        
        if (!CalculatePositionSize) s += "Pos Size = " + DoubleToString(FixedPositionSize, CountDecimalPlaces(FixedPositionSize)) + " lots";
        else
        {
            if (UseMoneyInsteadOfPercentage) s += "Risk = " + DoubleToString(MoneyRisk, CountDecimalPlaces(AccountInfoDouble(ACCOUNT_BALANCE))) + " " + AccountInfoString(ACCOUNT_CURRENCY);
            else if (UseEquityInsteadOfBalance) s += "Risk = " + DoubleToString(Risk, CountDecimalPlaces(Risk)) + "% of Equity (" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + " " + AccountInfoString(ACCOUNT_CURRENCY) + ")";
            else if (FixedBalance > 0) s += "Risk = " + DoubleToString(Risk, CountDecimalPlaces(Risk)) + "% of " + DoubleToString(FixedBalance, CountDecimalPlaces(AccountInfoDouble(ACCOUNT_BALANCE))) + " " + AccountInfoString(ACCOUNT_CURRENCY);
            else s += "Risk = " + DoubleToString(Risk, CountDecimalPlaces(Risk)) + "% of Balance (" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), CountDecimalPlaces(AccountInfoDouble(ACCOUNT_BALANCE))) + " " + AccountInfoString(ACCOUNT_CURRENCY) + ")";
        }
    }    

    s += "\n";
    
    datetime current_time;
    if (TimeType == TIME_TYPE_SERVER) current_time = TimeCurrent();
    else current_time = TimeLocal();
    
    datetime order_time = OrderTime;
    if (DailyMode) order_time = GetOrderTimeForDailyMode(current_time);
    
    int difference = (int)current_time - (int)order_time;
    
    if (difference <= 0) s += "Time to order: " + TimeDistance(-difference);
    else s += "Time after order: " + TimeDistance(difference);
    if (DailyMode)
    {
        if (difference < -10) WillNoLongerTryOpeningTrade = false; // Reset for further order taking.
        s += " (daily mode)";
    }
    s += ".";

    Comment(s);
}

//+------------------------------------------------------------------+
//| Format time distance from the number of seconds to normal string |
//| of years, days, hours, minutes, and seconds.                     |
//| t - number of seconds                                            |
//| Returns: formatted string.                                       |
//+------------------------------------------------------------------+
string TimeDistance(int t)
{
    if (t == 0) return "0 seconds";
    string s = "";
    int y = 0;
    int d = 0;
    int h = 0;
    int m = 0;

    y = t / 31536000;
    t -= y * 31536000;

    d = t / 86400;
    t -= d * 86400;

    h = t / 3600;
    t -= h * 3600;

    m = t / 60;
    t -= m * 60;

    if (y) s += IntegerToString(y) + " year";
    if (y > 1) s += "s";

    if (d) s += " " + IntegerToString(d) + " day";
    if (d > 1) s += "s";

    if (h) s += " " + IntegerToString(h) + " hour";
    if (h > 1) s += "s";

    if (m) s += " " + IntegerToString(m) + " minute";
    if (m > 1) s += "s";

    if (t) s += " " + IntegerToString(t) + " second";
    if (t > 1) s += "s";

    StringTrimLeft(s);
    return s;
}

string OrderToString(ENUM_ORDER_TYPE ot)
{
    if (ot == ORDER_TYPE_BUY) return "Buy";
    if (ot == ORDER_TYPE_SELL) return "Sell";
    if (ot == ORDER_TYPE_BUY_LIMIT) return "Buy Limit";
    if (ot == ORDER_TYPE_BUY_STOP) return "Buy Stop";
    if (ot == ORDER_TYPE_SELL_LIMIT) return "Sell Limit";
    if (ot == ORDER_TYPE_SELL_STOP) return "Sell Stop";
    if (ot == ORDER_TYPE_BUY_STOP_LIMIT) return "Buy Stop Limit";
    if (ot == ORDER_TYPE_SELL_STOP_LIMIT) return "Sell Stop Limit";
    return "";
}


// Returns true on correct time, false on incorrect time.
bool CheckTime(string time)
{
    if (StringLen(time) == 7) time = "0" + time;

    if (
        // Wrong length.
        (StringLen(time) != 8) ||
        // Wrong separator.
        (time[2] != ':') ||
        // Wrong first number (only 24 hours in a day).
        ((time[0] < '0') || (time[0] > '2')) ||
        // 00 to 09 and 10 to 19.
        (((time[0] == '0') || (time[0] == '1')) && ((time[1] < '0') || (time[1] > '9'))) ||
        // 20 to 23.
        ((time[0] == '2') && ((time[1] < '0') || (time[1] > '3'))) ||
        // 0M to 5M.
        ((time[3] < '0') || (time[3] > '5')) ||
        // M0 to M9.
        ((time[4] < '0') || (time[4] > '9')) ||
        // Wrong second separator.
        (time[5] != ':') ||
        // 0S to 5S.
        ((time[6] < '0') || (time[6] > '5')) ||
        // S0 to S9.
        ((time[7] < '0') || (time[7] > '9'))
    ) return false; // Failure.

    return true; // Success.
}

datetime GetOrderTimeForDailyMode(datetime current_time)
{
    bool skip_current_day = false;
    datetime target_time = StringToTime(TimeToString(current_time, TIME_DATE) + " " + DailyTime); // It's important to get the target time of the appropriate day (local/server).
    if (current_time > target_time + 10) skip_current_day = true; // Skip the current day. Give a 10 seconds buffer.
    // Find the next enabled day:
    for (int i = 0; i <= 7; i++, target_time += 24 * 60 * 60) // <= because the next day could be the same day of the week.
    {
        if ((i == 0) && (skip_current_day))
        {
            continue;
        }
        MqlDateTime target_time_struct;
        TimeToStruct(target_time, target_time_struct);
        if (EnabledDays[target_time_struct.day_of_week]) break;
    }

    return target_time;
}
//+------------------------------------------------------------------+