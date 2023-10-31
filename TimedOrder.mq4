//+------------------------------------------------------------------+
//|                                                      Timed Order |
//|                                  Copyright © 2023, EarnForex.com |
//|                                       https://www.earnforex.com/ |
//+------------------------------------------------------------------+
#property copyright "Copyright © 2023, EarnForex"
#property link      "https://www.earnforex.com/metatrader-expert-advisors/TimedOrder/"
#property version   "1.001"
#property strict

#include <stdlib.mqh>

#property description "Opens a trade (market or pending order) at specified time."

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
    BETTER_ORDER_TYPE_SELLSTOP // Sell Stop
};

// Change trade type to new enum to define only Buy, Sell, and four pendings.

input group "Trading"
input datetime OrderTime = __DATETIME__; // Date/time (server) to open order
input ENUM_BETTER_ORDER_TYPE OrderType = BETTER_ORDER_TYPE_BUY; // Order type
input double Entry = 0; // Entry price (optional unless pending)
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
input int Slippage = 30; // Maximum slippage in points
input ENUM_TIMEFRAMES ATR_Timeframe = PERIOD_CURRENT; // ATR Timeframe
input int ATR_Period = 14; // ATR Period
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
int global_ticket = 0;
ENUM_ORDER_TYPE TradeType;
int last_error;

// For tick value adjustment:
string ProfitCurrency = "", account_currency = "", BaseCurrency = "", ReferenceSymbol = NULL, AdditionalReferenceSymbol = NULL;
bool ReferenceSymbolMode, AdditionalReferenceSymbolMode;
int ProfitCalcMode;

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
        Output("Wrong input parambers! " + Error);
        CanWork = false;
        return INIT_SUCCEEDED;
        //return INIT_FAILED; // Bad idea because it will wipe all the input parameters entered by the users.
    }
    
    EventSetMillisecondTimer(100);
    
    CanWork = true;
    WillNoLongerTryOpeningTrade = false;
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
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

//+-----------------------------------------------------------------------------------+
//| Calculates necessary adjustments for cases when ProfitCurrency != AccountCurrency.|
//+-----------------------------------------------------------------------------------+
#define FOREX_SYMBOLS_ONLY 0
#define NONFOREX_SYMBOLS_ONLY 1
double CalculateAdjustment()
{
    double add_coefficient = 1; // Might be necessary for correction coefficient calculation if two pairs are used for profit currency to account currency conversion. This is handled differently in MT5 version.
    if (ReferenceSymbol == NULL)
    {
        ReferenceSymbol = GetSymbolByCurrencies(ProfitCurrency, account_currency, FOREX_SYMBOLS_ONLY);
        if (ReferenceSymbol == NULL) ReferenceSymbol = GetSymbolByCurrencies(ProfitCurrency, account_currency, NONFOREX_SYMBOLS_ONLY);
        ReferenceSymbolMode = true;
        // Failed.
        if (ReferenceSymbol == NULL)
        {
            // Reversing currencies.
            ReferenceSymbol = GetSymbolByCurrencies(account_currency, ProfitCurrency, FOREX_SYMBOLS_ONLY);
            if (ReferenceSymbol == NULL) ReferenceSymbol = GetSymbolByCurrencies(account_currency, ProfitCurrency, NONFOREX_SYMBOLS_ONLY);
            ReferenceSymbolMode = false;
        }
        if (ReferenceSymbol == NULL)
        {
            // The condition checks whether we are caclulating conversion coefficient for the chart's symbol or for some other.
            // The error output is OK for the current symbol only because it won't be repeated ad infinitum.
            // It should be avoided for non-chart symbols because it will just flood the log.
            Print("Couldn't detect proper currency pair for adjustment calculation. Profit currency: ", ProfitCurrency, ". Account currency: ", account_currency, ". Trying to find a possible two-symbol combination.");
            if ((FindDoubleReferenceSymbol("USD"))  // USD should work in 99.9% of cases.
             || (FindDoubleReferenceSymbol("EUR"))  // For very rare cases.
             || (FindDoubleReferenceSymbol("GBP"))  // For extremely rare cases.
             || (FindDoubleReferenceSymbol("JPY"))) // For extremely rare cases.
            {
                Print("Converting via ", ReferenceSymbol, " and ", AdditionalReferenceSymbol, ".");
            }
            else
            {
                Print("Adjustment calculation critical failure. Failed both simple and two-pair conversion methods.");
                return 1;
            }
        }
    }
    if (AdditionalReferenceSymbol != NULL) // If two reference pairs are used.
    {
        // Calculate just the additional symbol's coefficient and then use it in final return's multiplication.
        MqlTick tick;
        SymbolInfoTick(AdditionalReferenceSymbol, tick);
        add_coefficient = GetCurrencyCorrectionCoefficient(tick, AdditionalReferenceSymbolMode);
    }
    MqlTick tick;
    SymbolInfoTick(ReferenceSymbol, tick);
    return GetCurrencyCorrectionCoefficient(tick, ReferenceSymbolMode) * add_coefficient;
}

//+---------------------------------------------------------------------------+
//| Returns a currency pair with specified base currency and profit currency. |
//+---------------------------------------------------------------------------+
string GetSymbolByCurrencies(const string base_currency, const string profit_currency, const uint symbol_type)
{
    // Cycle through all symbols.
    for (int s = 0; s < SymbolsTotal(false); s++)
    {
        // Get symbol name by number.
        string symbolname = SymbolName(s, false);
        string b_cur;

        // Normal case - Forex pairs:
        if (MarketInfo(symbolname, MODE_PROFITCALCMODE) == 0)
        {
            if (symbol_type == NONFOREX_SYMBOLS_ONLY) continue; // Avoid checking symbols of a wrong type.
            // Get its base currency.
            b_cur = SymbolInfoString(symbolname, SYMBOL_CURRENCY_BASE);
            if (b_cur == "RUR") b_cur = "RUB";
        }
        else // Weird case for brokers that set conversion pairs as CFDs.
        {
            if (symbol_type == FOREX_SYMBOLS_ONLY) continue; // Avoid checking symbols of a wrong type.
            // Get its base currency as the initial three letters - prone to huge errors!
            b_cur = StringSubstr(symbolname, 0, 3);
        }

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

//+----------------------------------------------------------------------------+
//| Finds reference symbols using 2-pair method.                               |
//| Results are returned via reference parameters.                             |
//| Returns true if found the pairs, false otherwise.                          |
//+----------------------------------------------------------------------------+
bool FindDoubleReferenceSymbol(const string cross_currency)
{
    // A hypothetical example for better understanding:
    // The trader buys CAD/CHF.
    // account_currency is known = SEK.
    // cross_currency = USD.
    // profit_currency = CHF.
    // I.e., we have to buy dollars with francs (using the Ask price) and then sell those for SEKs (using the Bid price).

    ReferenceSymbol = GetSymbolByCurrencies(cross_currency, account_currency, FOREX_SYMBOLS_ONLY); 
    if (ReferenceSymbol == NULL) ReferenceSymbol = GetSymbolByCurrencies(cross_currency, account_currency, NONFOREX_SYMBOLS_ONLY);
    ReferenceSymbolMode = true; // If found, we've got USD/SEK.

    // Failed.
    if (ReferenceSymbol == NULL)
    {
        // Reversing currencies.
        ReferenceSymbol = GetSymbolByCurrencies(account_currency, cross_currency, FOREX_SYMBOLS_ONLY);
        if (ReferenceSymbol == NULL) ReferenceSymbol = GetSymbolByCurrencies(account_currency, cross_currency, NONFOREX_SYMBOLS_ONLY);
        ReferenceSymbolMode = false; // If found, we've got SEK/USD.
    }
    if (ReferenceSymbol == NULL)
    {
        Print("Error. Couldn't detect proper currency pair for 2-pair adjustment calculation. Cross currency: ", cross_currency, ". Account currency: ", account_currency, ".");
        return false;
    }

    AdditionalReferenceSymbol = GetSymbolByCurrencies(cross_currency, ProfitCurrency, FOREX_SYMBOLS_ONLY); 
    if (AdditionalReferenceSymbol == NULL) AdditionalReferenceSymbol = GetSymbolByCurrencies(cross_currency, ProfitCurrency, NONFOREX_SYMBOLS_ONLY);
    AdditionalReferenceSymbolMode = false; // If found, we've got USD/CHF. Notice that mode is swapped for cross/profit compared to cross/acc, because it is used in the opposite way.

    // Failed.
    if (AdditionalReferenceSymbol == NULL)
    {
        // Reversing currencies.
        AdditionalReferenceSymbol = GetSymbolByCurrencies(ProfitCurrency, cross_currency, FOREX_SYMBOLS_ONLY);
        if (AdditionalReferenceSymbol == NULL) AdditionalReferenceSymbol = GetSymbolByCurrencies(ProfitCurrency, cross_currency, NONFOREX_SYMBOLS_ONLY);
        AdditionalReferenceSymbolMode = true; // If found, we've got CHF/USD. Notice that mode is swapped for profit/cross compared to acc/cross, because it is used in the opposite way.
    }
    if (AdditionalReferenceSymbol == NULL)
    {
        Print("Error. Couldn't detect proper currency pair for 2-pair adjustment calculation. Cross currency: ", cross_currency, ". Chart's pair currency: ", ProfitCurrency, ".");
        return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//| Get profit correction coefficient based on current prices.       |
//| Valid for loss calculation only.                                 |
//+------------------------------------------------------------------+
double GetCurrencyCorrectionCoefficient(MqlTick &tick, const bool ref_symbol_mode)
{
    if ((tick.ask == 0) || (tick.bid == 0)) return -1; // Data is not yet ready.
    // Reverse quote.
    if (ref_symbol_mode)
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

// Taken from PositionSizeCalculator indicator.
double GetPositionSize(double entry, double stoploss)
{
    double Size, RiskMoney, UnitCost, PositionSize = 0;
    ProfitCurrency = SymbolInfoString(Symbol(), SYMBOL_CURRENCY_PROFIT);
    BaseCurrency = SymbolInfoString(Symbol(), SYMBOL_CURRENCY_BASE);
    ProfitCalcMode = (int)MarketInfo(Symbol(), MODE_PROFITCALCMODE);
    account_currency = AccountCurrency();

    // A rough patch for cases when account currency is set as RUR instead of RUB.
    if (account_currency == "RUR") account_currency = "RUB";
    if (ProfitCurrency == "RUR") ProfitCurrency = "RUB";
    if (BaseCurrency == "RUR") BaseCurrency = "RUB";

    double LotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
    int LotStep_digits = CountDecimalPlaces(LotStep);

    double SL = MathAbs(entry - stoploss);

    if (!CalculatePositionSize) return FixedPositionSize;

    if (AccountCurrency() == "") return 0;

    if (FixedBalance > 0)
    {
        Size = FixedBalance;
    }
    else if (UseEquityInsteadOfBalance)
    {
        Size = AccountEquity();
    }
    else
    {
        Size = AccountBalance();
    }

    if (!UseMoneyInsteadOfPercentage) RiskMoney = Size * Risk / 100;
    else RiskMoney = MoneyRisk;

    // If Symbol is CFD.
    if (ProfitCalcMode == 1)
        UnitCost = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE) * SymbolInfoDouble(Symbol(), SYMBOL_TRADE_CONTRACT_SIZE); // Apparently, it is more accurate than taking TICKVALUE directly in some cases.
    else UnitCost = MarketInfo(Symbol(), MODE_TICKVALUE); // Futures or Forex.

    if (ProfitCalcMode != 0)  // Non-Forex might need to be adjusted.
    {
        // If profit currency is different from account currency.
        if (ProfitCurrency != account_currency)
        {
            double CCC = CalculateAdjustment(); // Valid only for loss calculation.
            // Adjust the unit cost.
            UnitCost *= CCC;
        }
    }

    // If account currency == pair's base currency, adjust UnitCost to future rate (SL). Works only for Forex pairs.
    if ((account_currency == BaseCurrency) && (ProfitCalcMode == 0))
    {
        double current_rate = 1, future_rate = stoploss;
        RefreshRates();
        if (stoploss < entry)
        {
            current_rate = Ask;
        }
        else if (stoploss > entry)
        {
            current_rate = Bid;
        }
        UnitCost *= (current_rate / future_rate);
    }

    double TickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    
    if ((SL != 0) && (UnitCost != 0) && (TickSize != 0)) PositionSize = NormalizeDouble(RiskMoney / (SL * UnitCost / TickSize), LotStep_digits);

    if (PositionSize < MarketInfo(Symbol(), MODE_MINLOT)) PositionSize = MarketInfo(Symbol(), MODE_MINLOT);
    else if (PositionSize > MarketInfo(Symbol(), MODE_MAXLOT)) PositionSize = MarketInfo(Symbol(), MODE_MAXLOT);
    double steps = PositionSize / SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    if (MathFloor(steps) < steps) PositionSize = MathFloor(steps) * MarketInfo(Symbol(), MODE_LOTSTEP);
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
    datetime time;
    if (TimeType == TIME_TYPE_SERVER) time = TimeCurrent();
    else time = TimeLocal();
    if (time < OrderTime) return;

    // Time is due. At this point, if somethign fails, the EA won't try again until it is reloaded.
    WillNoLongerTryOpeningTrade = true;

    double SL = 0, TP = 0;

    if (SLType == SLTP_TYPE_ATR) SL = iATR(Symbol(), ATR_Timeframe, ATR_Period, 0) * StopLoss;
    else if (SLType == SLTP_TYPE_SPREADS) SL = SymbolInfoInteger(Symbol(), SYMBOL_SPREAD) * StopLoss * Point();
    else if (SLType == SLTP_TYPE_DISTANCE) SL = StopLoss * Point();
    else SL = StopLoss; // Level.

    if (TPType == SLTP_TYPE_ATR) TP = iATR(Symbol(), ATR_Timeframe, ATR_Period, 0) * TakeProfit;
    else if (TPType == SLTP_TYPE_SPREADS) TP = SymbolInfoInteger(Symbol(), SYMBOL_SPREAD) * TakeProfit * Point();
    else if (TPType == SLTP_TYPE_DISTANCE) TP = TakeProfit * Point();
    else TP = TakeProfit; // Level.

    // Prevent position opening when the spread is too wide (greater than MaxSpread input).
    int spread = (int)SymbolInfoInteger(Symbol(), SYMBOL_SPREAD);
    if ((MaxSpread > 0) && (spread > MaxSpread))
    {
        string explanation = "Current spread " + IntegerToString(spread) + " > maximum spread " + IntegerToString(MaxSpread) + ". Not opening the trade.";
        Output(explanation);
        if (AlertsOnFailure)
        {
            string Text;
            Text = Symbol() + " @ " + StringSubstr(EnumToString((ENUM_TIMEFRAMES)Period()), 7) + " - " + OrderToString(TradeType) + ". " + explanation;
            if (EnableNativeAlerts) Alert(Text);
            if (EnableEmailAlerts) SendMail("Timed Order Alert - " + Symbol() + " @ " + StringSubstr(EnumToString((ENUM_TIMEFRAMES)Period()), 7), Text);
            if (EnablePushAlerts) SendNotification(Text);
        }
        global_ticket = -1;
        return;
    }

    int ticket = 0;
    ENUM_ORDER_TYPE order_type = TradeType; // Might get updated in pending mode. Should be reflected in the alerts.
    if ((TradeType == OP_BUY) || (TradeType == OP_SELL)) // Market
    {
        double price = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
        if (TradeType == OP_SELL) price = SymbolInfoDouble(Symbol(), SYMBOL_BID);
        if ((SLType != SLTP_TYPE_PRICELEVEL) && (SL != 0))
        {
            // Get SL as price level.
            if (TradeType == OP_BUY) SL = price - SL;
            else if (TradeType == OP_SELL) SL = price + SL;
        }
        if ((TPType != SLTP_TYPE_PRICELEVEL) && (TP != 0))
        {
            // Get TP as price level.
            if (TradeType == OP_BUY) TP = price + TP;
            else if (TradeType == OP_SELL) TP = price - TP;
        }
        if ((MaxDifference > 0) && (MathAbs(Entry - price) > MaxDifference * Point()))
        {
            string explanation = "Price difference " + DoubleToString(MathAbs(Entry - price), _Digits) + " > maximum price difference " + DoubleToString((double)MaxDifference * Point(), _Digits) + ". Not opening the trade.";
            Output(explanation);
            if (AlertsOnFailure)
            {
                string Text;
                Text = Symbol() + " @ " + StringSubstr(EnumToString((ENUM_TIMEFRAMES)Period()), 7) + " - " + OrderToString(TradeType) + ". " + explanation;
                if (EnableNativeAlerts) Alert(Text);
                if (EnableEmailAlerts) SendMail("Timed Order Alert - " + Symbol() + " @ " + StringSubstr(EnumToString((ENUM_TIMEFRAMES)Period()), 7), Text);
                if (EnablePushAlerts) SendNotification(Text);
            }
            global_ticket = -1;
            return;
        }
        ticket = ExecuteMarketOrder(TradeType, GetPositionSize(price, SL), price, SL, TP);
    }
    else // Pending
    {
        // Modify trade type based on the current price.
        double price = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
        if ((TradeType == OP_SELLSTOP) || (TradeType == OP_SELLLIMIT)) price = SymbolInfoDouble(Symbol(), SYMBOL_BID);
        if ((TradeType == OP_BUYSTOP) && (Entry < price)) order_type = OP_BUYLIMIT;
        else if ((TradeType == OP_BUYLIMIT) && (Entry > price)) order_type = OP_BUYSTOP;
        else if ((TradeType == OP_SELLSTOP) && (Entry > price)) order_type = OP_SELLLIMIT;
        else if ((TradeType == OP_SELLLIMIT) && (Entry < price)) order_type = OP_SELLSTOP;
        
        if ((SLType != SLTP_TYPE_PRICELEVEL) && (SL != 0))
        {
            // Get SL as price level.
            if ((order_type == OP_BUYSTOP) || (order_type == OP_BUYLIMIT)) SL = Entry - SL;
            else if ((order_type == OP_SELLSTOP) || (order_type == OP_SELLLIMIT)) SL = Entry + SL;
        }
        if ((TPType != SLTP_TYPE_PRICELEVEL) && (TP != 0))
        {
            // Get TP as price level.
            if ((order_type == OP_BUYSTOP) || (order_type == OP_BUYLIMIT)) TP = Entry + TP;
            else if ((order_type == OP_SELLSTOP) || (order_type == OP_SELLLIMIT)) TP = Entry - TP;
        }
        ticket = CreatePendingOrder(order_type, GetPositionSize(Entry, SL), Entry, SL, TP);
    }

    if (ticket > 0)
    {
        double LotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
        int LotStep_digits = CountDecimalPlaces(LotStep);
        if (!OrderSelect(ticket, SELECT_BY_TICKET))
        {
            PostOrderText = "Failed to select order: " + IntegerToString(GetLastError()) + " (" + ErrorDescription(GetLastError()) + ")";
            Output(PostOrderText);
        }
        else
        {
            PostOrderText = DoubleToString(OrderLots(), LotStep_digits) + " lots; Open = " + DoubleToString(OrderOpenPrice(), _Digits);
            if (SL != 0) PostOrderText += " SL = " + DoubleToString(OrderStopLoss(), _Digits);
            if (TP != 0) PostOrderText += " TP = " + DoubleToString(OrderTakeProfit(), _Digits);
            if (OrderExpiration() > 0) PostOrderText += " Expiration = " + TimeToString(OrderExpiration());
        }
        global_ticket = ticket;
        
        if (AlertsOnSuccess)
        {
            string Text;
            Text = Symbol() + " @ " + StringSubstr(EnumToString((ENUM_TIMEFRAMES)Period()), 7) + " - " + OrderToString(order_type) + ". Created: " + PostOrderText;
            if (EnableNativeAlerts) Alert(Text);
            if (EnableEmailAlerts) SendMail("Timed Order Alert - " + Symbol() + " @ " + StringSubstr(EnumToString((ENUM_TIMEFRAMES)Period()), 7), Text);
            if (EnablePushAlerts) SendNotification(Text);
        }
    }
    else
    {
        if (AlertsOnFailure)
        {
            string Text;
            Text = Symbol() + " @ " + StringSubstr(EnumToString((ENUM_TIMEFRAMES)Period()), 7) + " - " + OrderToString(order_type) + ". Failed after " + IntegerToString(Retries) + " tries: " + IntegerToString(last_error) + " (" + ErrorDescription(last_error) + ")";
            if (EnableNativeAlerts) Alert(Text);
            if (EnableEmailAlerts) SendMail("Timed Order Alert - " + Symbol() + " @ " + StringSubstr(EnumToString((ENUM_TIMEFRAMES)Period()), 7), Text);
            if (EnablePushAlerts) SendNotification(Text);
        }
    }
}

//+------------------------------------------------------------------+
//| Execute a market order.                                          |
//+------------------------------------------------------------------+
int ExecuteMarketOrder(const int order_type, const double volume, const double price, const double sl, const double tp)
{
    double LotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
    int LotStep_digits = CountDecimalPlaces(LotStep);
    int ticket = 0;
    for (int i = 0; i < Retries; i++)
    {
        ticket = OrderSend(Symbol(), order_type, NormalizeDouble(volume, LotStep_digits), NormalizeDouble(price, _Digits), Slippage, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), OrderCommentary, Magic);
        if (ticket == -1)
        {
            last_error = GetLastError();
            string order_string = OrderToString((ENUM_ORDER_TYPE)order_type);
            int StopLevel = (int)SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL);

            Output("Error Sending " + order_string + ": " + IntegerToString(last_error) + " (" + ErrorDescription(last_error) + ")");
            Output("Volume = " + DoubleToString(volume, LotStep_digits) + " Entry = " + DoubleToString(price, _Digits) + " SL = " + DoubleToString(sl, _Digits) + " TP = " + DoubleToString(tp, _Digits) + " StopLevel = " + IntegerToString(StopLevel));
        }
        else
        {
            Output("Order executed. Ticket: " + IntegerToString(ticket) + ".");
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
int CreatePendingOrder(const int order_type, const double volume, const double price, const double sl, const double tp)
{
    double LotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
    int LotStep_digits = CountDecimalPlaces(LotStep);
    int ticket = 0;
    for (int i = 0; i < Retries; i++)
    {
        ticket = OrderSend(Symbol(), order_type, NormalizeDouble(volume, LotStep_digits), NormalizeDouble(price, _Digits), Slippage, NormalizeDouble(sl, _Digits), NormalizeDouble(tp, _Digits), OrderCommentary, Magic, Expires);
        if (ticket == -1)
        {
            last_error = GetLastError();
            string order_string = OrderToString((ENUM_ORDER_TYPE)order_type);
            int StopLevel = (int)SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL);

            Output("Error Sending " + order_string + ": " + IntegerToString(last_error) + " (" + ErrorDescription(last_error) + ")");
            Output("Volume = " + DoubleToString(volume, LotStep_digits) + " Entry = " + DoubleToString(price, _Digits) + " SL = " + DoubleToString(sl, _Digits) + " TP = " + DoubleToString(tp, _Digits) + " StopLevel = " + IntegerToString(StopLevel));
        }
        else
        {
            Output("Order created. Ticket: " + IntegerToString(ticket) + ".");
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
    // Order time has already passed.
    if (((TimeType == TIME_TYPE_SERVER) && (OrderTime <= TimeCurrent())) ||
        ((TimeType == TIME_TYPE_LOCAL) && (OrderTime <= TimeLocal()))) return "Order time has already passed.";
    
    // Pending order with zero entry.
    if ((TradeType != OP_BUY) && (TradeType != OP_SELL) && (Entry == 0)) return "Entry price cannot be zero for pending orders.";
    
    // SL on the wrong side.
    if ((StopLoss != 0) && (SLType == SLTP_TYPE_PRICELEVEL))
    {
        if (StopLoss >= Entry)
        {
            if (TradeType == OP_BUYSTOP) return "Stop-loss cannot be above entry for a Buy Stop.";
            if (TradeType == OP_BUYLIMIT) return "Stop-loss cannot be above entry for a Buy Limit.";
        }
        if (StopLoss <= Entry)
        {
            if (TradeType == OP_SELLSTOP) return "Stop-loss cannot be below entry for a Sell Stop.";
            if (TradeType == OP_SELLLIMIT) return "Stop-loss cannot be below entry for a Sell Limit.";
        }
    }
    if ((TakeProfit != 0) && (TPType == SLTP_TYPE_PRICELEVEL))
    {
        if (TakeProfit <= Entry)
        {
            if (TradeType == OP_BUYSTOP) return "Take-profit cannot be below entry for a Buy Stop.";
            if (TradeType == OP_BUYLIMIT) return "Take-profit cannot be below entry for a Buy Limit.";
        }
        if (TakeProfit >= Entry)
        {
            if (TradeType == OP_SELLSTOP) return "Take-profit cannot be above entry for a Sell Stop.";
            if (TradeType == OP_SELLLIMIT) return "Take-profit cannot be above entry for a Sell Limit.";
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
    account_currency = "";
    BaseCurrency = "";
    ReferenceSymbol = NULL;
    AdditionalReferenceSymbol = NULL;
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

    if ((TradeType == OP_BUYSTOP) || (TradeType == OP_BUYLIMIT) || (TradeType == OP_SELLSTOP) || (TradeType == OP_SELLLIMIT)) s += " @ " + DoubleToString(Entry, _Digits);
    
    if (global_ticket != 0) // Order already executed or tried to execute.
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
            if (UseMoneyInsteadOfPercentage) s += "Risk = " + DoubleToString(MoneyRisk, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY);
            else if (UseEquityInsteadOfBalance) s += "Risk = " + DoubleToString(Risk, CountDecimalPlaces(Risk)) + "% of Equity (" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + " " + AccountInfoString(ACCOUNT_CURRENCY) + ")";
            else if (FixedBalance > 0) s += "Risk = " + DoubleToString(Risk, CountDecimalPlaces(Risk)) + "% of " + DoubleToString(FixedBalance, 2) + " " + AccountInfoString(ACCOUNT_CURRENCY);
            else s += "Risk = " + DoubleToString(Risk, CountDecimalPlaces(Risk)) + "% of Balance (" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + " " + AccountInfoString(ACCOUNT_CURRENCY) + ")";
        }
    }    

    s += "\n";
    
    datetime time;
    if (TimeType == TIME_TYPE_SERVER) time = TimeCurrent();
    else time = TimeLocal();
    int difference = (int)time - (int)OrderTime;
    if (difference <= 0) s += "Time to order: " + TimeDistance(-difference) + ".";
    else s += "Time after order: " + TimeDistance(difference) + ".";

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

    return StringTrimLeft(s);
}

string OrderToString(ENUM_ORDER_TYPE ot)
{
    if (ot == OP_BUY) return "Buy";
    if (ot == OP_SELL) return "Sell";
    if (ot == OP_BUYLIMIT) return "Buy Limit";
    if (ot == OP_BUYSTOP) return "Buy Stop";
    if (ot == OP_SELLLIMIT) return "Sell Limit";
    if (ot == OP_SELLSTOP) return "Sell Stop";
    return "";
}
//+------------------------------------------------------------------+