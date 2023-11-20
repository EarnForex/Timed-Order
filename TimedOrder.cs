// -------------------------------------------------------------------------------
//   Opens a trade (market or pending order) at the specified time.
//   One-time or daily.
//
//   As of 2023-11-20, Stop Limit orders in cTrader don't make much sense, so they aren't implemented in this EA.
//
//   Version 1.01.
//   Copyright 2023, EarnForex.com
//   https://www.earnforex.com/metatrader-expert-advisors/TimedOrder/
// -------------------------------------------------------------------------------

using System;
using System.Linq;
using cAlgo.API;
using cAlgo.API.Indicators;
using cAlgo.API.Internals;
using cAlgo.Indicators;

namespace cAlgo
{
    [Robot(TimeZone = TimeZones.UTC, AccessRights = AccessRights.None)]
    public class TimedOrder : Robot
    {
        public enum ENUM_BETTER_ORDER_TYPE
        {
            Buy, // Buy
            Sell, // Sell
            Buy_Limit, // Buy Limit
            Sell_Limit, // Sell Limit
            Buy_Stop, // Buy Stop
            Sell_Stop // Sell Stop
        }
        
        public enum ENUM_SLTP_TYPE
        {
            Price_Level, // Price level (might be unfit for a market order)
            Distance, // Distance from entry in points
            ATR, // ATR-based with multiplier
            Spreads // Number of spreads
        }
        
        public enum ENUM_TIME_TYPE
        {
            Local, // Local time
            Server // Server time
        }
        
        [Parameter("=== Trading", DefaultValue = "=================")]
        public string MainSettings { get; set; }
        
        [Parameter("Time type", DefaultValue = ENUM_TIME_TYPE.Server)]
        public ENUM_TIME_TYPE TimeType { get; set; }
    
        [Parameter("=Order time", DefaultValue = "=")]
        public string Comment1 { get; set; }

        [Parameter(DefaultValue = 2022, MinValue = 1970)]
        public int Year { get; set; }

        [Parameter(DefaultValue = 9, MinValue = 1, MaxValue = 12)]
        public int Month { get; set; }

        [Parameter(DefaultValue = 20, MinValue = 1, MaxValue = 31)]
        public int Day { get; set; }

        [Parameter(DefaultValue = 0, MinValue = 0, MaxValue = 23)]
        public int Hour { get; set; }

        [Parameter(DefaultValue = 0, MinValue = 0, MaxValue = 59)]
        public int Minute { get; set; }

        [Parameter(DefaultValue = 0, MinValue = 0, MaxValue = 59)]
        public int Second { get; set; }

        [Parameter("Order type", DefaultValue = ENUM_BETTER_ORDER_TYPE.Buy)]
        public ENUM_BETTER_ORDER_TYPE OrderType { get; set; }

        [Parameter("Entry price (optional)", DefaultValue = 0, MinValue = 0)]
        public double Entry { get; set; }

        [Parameter("Entry distance in points (for pending)", DefaultValue = 0, MinValue = 0)]
        public int EntryDistancePoints { get; set; }

        [Parameter("Stop-loss type", DefaultValue = ENUM_SLTP_TYPE.Price_Level)]
        public ENUM_SLTP_TYPE SLType { get; set; }

        [Parameter(DefaultValue = 0, MinValue = 0)]
        public double StopLoss { get; set; }

        [Parameter("Take-profit type", DefaultValue = ENUM_SLTP_TYPE.Price_Level)]
        public ENUM_SLTP_TYPE TPType { get; set; }

        [Parameter(DefaultValue = 0, MinValue = 0)]
        public double TakeProfit { get; set; }


        [Parameter("=== Control", DefaultValue = "=================")]
        public string OrderManagement { get; set; }
        
        [Parameter("=Expiration time (for pending orders, server time)", DefaultValue = "=")]
        public string Comment2 { get; set; }

        [Parameter(DefaultValue = 1970, MinValue = 1970)]
        public int YearExp { get; set; }

        [Parameter(DefaultValue = 1, MinValue = 1, MaxValue = 12)]
        public int MonthExp { get; set; }

        [Parameter(DefaultValue = 1, MinValue = 1, MaxValue = 31)]
        public int DayExp { get; set; }

        [Parameter(DefaultValue = 0, MinValue = 0, MaxValue = 23)]
        public int HourExp { get; set; }

        [Parameter(DefaultValue = 0, MinValue = 0, MaxValue = 59)]
        public int MinuteExp { get; set; }
        
        [Parameter(DefaultValue = 0, MinValue = 0, MaxValue = 59)]
        public int SecondExp { get; set; }

        [Parameter("How many times to try sending order before failure?", DefaultValue = 10, MinValue = 1)]
        public int Retries { get; set; }

        [Parameter("Max difference between given price and market price (points)", DefaultValue = 0, MinValue = 0)]
        public int MaxDifference { get; set; }

        [Parameter("Maximum spread in points", DefaultValue = 30, MinValue = 0)]
        public int MaxSpread { get; set; }

        [Parameter("Retry until spread falls below MaxSpread?", DefaultValue = false)]
        public bool RetryUntilMaxSpread { get; set; }

        [Parameter(DefaultValue = 1, MinValue = 0)]
        public int Slippage { get; set; }

        [Parameter("ATR Timeframe", DefaultValue = "Daily")]
        public TimeFrame ATR_Timeframe { get; set; }

        [Parameter("ATR Period", DefaultValue = 14, MinValue = 1)]
        public int ATR_Period { get; set; }
        

        [Parameter("=== Daily mode", DefaultValue = "=================")]
        public string DailyModeInputs { get; set; }

        [Parameter("Daily mode: if true, will trade every given day.", DefaultValue = false)]
        public bool DailyMode { get; set; }

        [Parameter(DefaultValue = 0, MinValue = 0, MaxValue = 23)]
        public int DailyHour { get; set; }

        [Parameter(DefaultValue = 0, MinValue = 0, MaxValue = 59)]
        public int DailyMinute { get; set; }

        [Parameter(DefaultValue = 0, MinValue = 0, MaxValue = 59)]
        public int DailySecond { get; set; }

        [Parameter(DefaultValue = true)]
        public bool Monday { get; set; }
        
        [Parameter(DefaultValue = true)]
        public bool Tuesday { get; set; }

        [Parameter(DefaultValue = true)]
        public bool Wednesday { get; set; }

        [Parameter(DefaultValue = true)]
        public bool Thursday { get; set; }

        [Parameter(DefaultValue = true)]
        public bool Friday { get; set; }

        [Parameter(DefaultValue = false)]
        public bool Saturday { get; set; }

        [Parameter(DefaultValue = false)]
        public bool Sunday { get; set; }

        [Parameter("=== Position sizing", DefaultValue = "=================")]
        public string PositionSizing { get; set; }

        [Parameter("CalculatePositionSize: Use money management module?", DefaultValue = false)]
        public bool CalculatePositionSize { get; set; }

        [Parameter("FixedPositionSize: Used if CalculatePositionSize = false.", DefaultValue = 0.01, MinValue = 0.01)]
        public double FixedPositionSize { get; set; }

        [Parameter("Risk, %", DefaultValue = 1, MinValue = 0)]
        public double Risk { get; set; }

        [Parameter("Risk, Money", DefaultValue = 0, MinValue = 0)]
        public double MoneyRisk { get; set; }

        [Parameter("Use Money Instead of %", DefaultValue = false)]
        public bool UseMoneyInsteadOfPercentage { get; set; }

        [Parameter("Use Equity Instead of Balance", DefaultValue = false)]
        public bool UseEquityInsteadOfBalance { get; set; }

        [Parameter("Fixed Balance", DefaultValue = 0, MinValue = 0)]
        public double FixedBalance { get; set; }
        

        [Parameter("=== Alerts", DefaultValue = "=================")]
        public string AlertsSettings { get; set; }

        [Parameter("Alert on success?", DefaultValue = false)]
        public bool AlertsOnSuccess { get; set; }

        [Parameter("Alert on failure?", DefaultValue = false)]
        public bool AlertsOnFailure { get; set; }

        [Parameter("AlertEmail: Email From.", DefaultValue = "")]
        public string AlertEmailFrom { get; set; }

        [Parameter("AlertEmail: Email To.", DefaultValue = "")]
        public string AlertEmailTo { get; set; }
        
        
        [Parameter("=== Miscellaneous", DefaultValue = "=================")]
        public string Miscellaneous { get; set; }

        [Parameter(DefaultValue = "TimedOrder")]
        public string Commentary { get; set; }

        [Parameter("Silent: If true, does not display any output via chart comment.", DefaultValue = false)]
        public bool Silent { get; set; }

        [Parameter("Vertical Corner", DefaultValue = VerticalAlignment.Top)]
        public VerticalAlignment CornerVertical { get; set; }

        [Parameter("Horizontal Corner", DefaultValue = HorizontalAlignment.Left)]
        public HorizontalAlignment CornerHorizontal { get; set; }

        // Indicator handles
        private AverageTrueRange ATR;
        private Bars tf_data; // For timeframe data to be used with ATR.

        private DateTime trade_time, expires_time, unix_epoch;
        private bool trade_done = false;
        private bool failure = false;

        private bool CanWork = false;
        private bool WillNoLongerTryOpeningTrade = false;
        private string PostOrderText = "";
        private bool[] EnabledDays; // For Daily Mode.
        
        protected override void OnStart()
        {
            trade_time = new DateTime(Year, Month, Day, Hour, Minute, Second);
            expires_time = new DateTime(YearExp, MonthExp, DayExp, HourExp, MinuteExp, SecondExp);
            unix_epoch = new DateTime(1970, 1, 1, 0, 0, 0);

            string Error = CheckInputParameters();
            if (Error != "")
            {
                if (!Silent) Chart.DrawStaticText("TimedOrder", "Wrong input parameters!\n" + Error, CornerVertical, CornerHorizontal, Color.Red);
                Print("Wrong input parameters! " + Error);
                CanWork = false;
                return;
            }

            if (!Silent)
            {
                Chart.DrawStaticText("NewsTraderTimer", "", CornerVertical, CornerHorizontal, Color.Red);
            }

            if ((SLType == ENUM_SLTP_TYPE.ATR) || (TPType == ENUM_SLTP_TYPE.ATR))
            {
                tf_data = MarketData.GetBars(ATR_Timeframe);
                ATR = Indicators.AverageTrueRange(tf_data, ATR_Period, MovingAverageType.Simple);
            }
            
            EnabledDays = new bool[7];
            EnabledDays[0] = Sunday;
            EnabledDays[1] = Monday;
            EnabledDays[2] = Tuesday;
            EnabledDays[3] = Wednesday;
            EnabledDays[4] = Thursday;
            EnabledDays[5] = Friday;
            EnabledDays[6] = Saturday;
            
            // For smooth updates.
            Timer.Start(TimeSpan.FromMilliseconds(100));

            CanWork = true;
            WillNoLongerTryOpeningTrade = false;
        }

//+------------------------------------------------------------------+
//| Updates text about time left to news or passed after news.       |
//+------------------------------------------------------------------+
        protected override void OnTimer()
        {
            if (!CanWork) return; // Don't operate if there was some initialization problem.
            if (!Silent) ShowStatus();
            if (!WillNoLongerTryOpeningTrade) DoTrading();
        }

        protected override void OnTick()
        {
            if (!CanWork) return; // Don't operate if there was some initialization problem.
            if (!Silent) ShowStatus();
            if (!WillNoLongerTryOpeningTrade) DoTrading();
        }

//+------------------------------------------------------------------+
//| Main execution procedure.                                        |
//+------------------------------------------------------------------+
        private void DoTrading()
        {
            DateTime order_time = trade_time;
            if (DailyMode) order_time = GetOrderTimeForDailyMode();

            // Do nothing if it is too early.
            TimeSpan difference;
            if (TimeType == ENUM_TIME_TYPE.Server) difference = Time.Subtract(order_time);
            else difference = DateTime.Now.Subtract(order_time);
            if (difference <= TimeSpan.FromMilliseconds(0)) return;
            
        
            double SL, TP;
            if (SLType == ENUM_SLTP_TYPE.ATR) SL = ATR.Result.LastValue * StopLoss;
            else if (SLType == ENUM_SLTP_TYPE.Spreads) SL = Symbol.Spread * StopLoss;
            else if (SLType == ENUM_SLTP_TYPE.Distance) SL = StopLoss * Symbol.TickSize;
            else SL = StopLoss; // Level.
        
            if (TPType == ENUM_SLTP_TYPE.ATR) TP = ATR.Result.LastValue * TakeProfit;
            else if (TPType == ENUM_SLTP_TYPE.Spreads) TP = Symbol.Spread * TakeProfit;
            else if (TPType == ENUM_SLTP_TYPE.Distance) TP = TakeProfit * Symbol.TickSize;
            else TP = TakeProfit; // Level.
        
            // Time is due. At this point, if something fails, the EA won't try again until it is reloaded.
            WillNoLongerTryOpeningTrade = true;
        
            // Prevent position opening when the spread is too wide (greater than MaxSpread input).
            double spread = Symbol.Spread;
            if ((MaxSpread > 0) && (spread / Symbol.TickSize > MaxSpread))
            {
                string explanation = "Current spread " + (spread / Symbol.TickSize).ToString() + " > maximum spread " + MaxSpread.ToString() + ". Not opening the trade.";
                if (RetryUntilMaxSpread) explanation += " Waiting for spread to go below the MaxSpread setting.";
                Print(explanation);
                if (RetryUntilMaxSpread)
                {
                    WillNoLongerTryOpeningTrade = false; // Let it try again.
                    return;
                }
                if (AlertsOnFailure)
                {
                    string Text = Symbol.Name + " @ " + TimeFrame.Name + " - " + OrderType.ToString() + ". " + explanation;
                    Notifications.SendEmail(AlertEmailFrom, AlertEmailTo, "Timed Order Alert - " + Symbol.Name + " @ " + TimeFrame.Name, Text);
                }
                failure = true;
                return;
            }
        
            TradeResult tr;
            ENUM_BETTER_ORDER_TYPE order_type = OrderType; // Might get updated in pending mode. Should be reflected in the alerts.
            if ((order_type == ENUM_BETTER_ORDER_TYPE.Buy) || (order_type == ENUM_BETTER_ORDER_TYPE.Sell)) // Market
            {
                double price = Symbol.Ask;
                if (order_type == ENUM_BETTER_ORDER_TYPE.Sell) price = Symbol.Bid;
                if ((SLType == ENUM_SLTP_TYPE.Price_Level) && (SL != 0)) SL = Math.Abs(price - SL);
                if ((TPType == ENUM_SLTP_TYPE.Price_Level) && (TP != 0)) TP = Math.Abs(price - TP);
                if ((MaxDifference > 0) && (Math.Abs(Entry - price) > MaxDifference * Symbol.TickSize))
                {
                    string explanation = "Price difference " + Math.Abs(Entry - price).ToString() + " > maximum price difference " + (MaxDifference * Symbol.TickSize).ToString() + ". Not opening the trade.";
                    Print(explanation);
                    if (AlertsOnFailure)
                    {
                        string Text = Symbol.Name + " @ " + TimeFrame.Name + " - " + OrderType.ToString() + ". " + explanation;
                        Notifications.SendEmail(AlertEmailFrom, AlertEmailTo, "Timed Order Alert - " + Symbol.Name + " @ " + TimeFrame.Name, Text);
                    }
                    failure = true;
                    return;
                }
                tr = ExecuteMarketOrder(order_type, GetPositionSize(SL / Symbol.PipSize), price, SL / Symbol.PipSize, TP / Symbol.PipSize);
        
                PostOrderText = Symbol.VolumeInUnitsToQuantity(tr.Position.VolumeInUnits).ToString() + " lots; Open = " + tr.Position.EntryPrice.ToString();
                if (SL != 0) PostOrderText += " SL = " + tr.Position.StopLoss.ToString();
                if (TP != 0) PostOrderText += " TP = " + tr.Position.TakeProfit.ToString();
            }
            else // Pending
            {
                // Modify trade type based on the current price.
                double price = Symbol.Ask;
                double entry = Entry;
                if ((OrderType == ENUM_BETTER_ORDER_TYPE.Sell_Stop) || (OrderType == ENUM_BETTER_ORDER_TYPE.Sell_Limit)) price = Symbol.Bid;

                if (EntryDistancePoints > 0)
                {
                    // order_type remains being equal TradeType.
                    if ((order_type == ENUM_BETTER_ORDER_TYPE.Buy_Stop) || (order_type == ENUM_BETTER_ORDER_TYPE.Sell_Limit)) entry = price + EntryDistancePoints * Symbol.TickSize;
                    else if ((order_type == ENUM_BETTER_ORDER_TYPE.Sell_Stop) || (order_type == ENUM_BETTER_ORDER_TYPE.Buy_Limit)) entry = price - EntryDistancePoints * Symbol.TickSize;
                }
                else
                {
                    if ((OrderType == ENUM_BETTER_ORDER_TYPE.Buy_Stop) && (Entry < price)) order_type = ENUM_BETTER_ORDER_TYPE.Buy_Limit;
                    else if ((OrderType == ENUM_BETTER_ORDER_TYPE.Buy_Limit) && (Entry > price)) order_type = ENUM_BETTER_ORDER_TYPE.Buy_Stop;
                    else if ((OrderType == ENUM_BETTER_ORDER_TYPE.Sell_Stop) && (Entry > price)) order_type = ENUM_BETTER_ORDER_TYPE.Sell_Limit;
                    else if ((OrderType == ENUM_BETTER_ORDER_TYPE.Sell_Limit) && (Entry < price)) order_type = ENUM_BETTER_ORDER_TYPE.Sell_Stop;
                }                
                if ((SLType == ENUM_SLTP_TYPE.Price_Level) && (SL != 0)) SL = Math.Abs(entry - SL);
                if ((TPType == ENUM_SLTP_TYPE.Price_Level) && (TP != 0)) TP = Math.Abs(entry - TP);

                tr = CreatePendingOrder(order_type, GetPositionSize(SL / Symbol.PipSize), entry, SL / Symbol.PipSize, TP / Symbol.PipSize);
        
                PostOrderText = Symbol.VolumeInUnitsToQuantity(tr.PendingOrder.VolumeInUnits).ToString() + " lots; Open = " + tr.PendingOrder.TargetPrice.ToString();
                if (SL != 0) PostOrderText += " SL = " + tr.PendingOrder.StopLoss.ToString();
                if (TP != 0) PostOrderText += " TP = " + tr.PendingOrder.TakeProfit.ToString();
                if (tr.PendingOrder.ExpirationTime.HasValue) PostOrderText += " Expiration = " + tr.PendingOrder.ExpirationTime.ToString();
            }
        
            trade_done = true;
            if (tr.IsSuccessful)
            {
                if (AlertsOnSuccess)
                {
                    string Text = Symbol.Name + " @ " + TimeFrame.Name + " - " + OrderType.ToString() + ". Created: " + PostOrderText;
                    Notifications.SendEmail(AlertEmailFrom, AlertEmailTo, "Timed Order Alert - " + Symbol.Name + " @ " + TimeFrame.Name, Text);
                }
            }
            else
            {
                failure = true;
                if (AlertsOnFailure)
                {
                    string Text = Symbol.Name + " @ " + TimeFrame.Name + " - " + OrderType.ToString() + ". Failed after " + Retries.ToString() + " tries.";
                    Notifications.SendEmail(AlertEmailFrom, AlertEmailTo, "Timed Order Alert - " + Symbol.Name + " @ " + TimeFrame.Name, Text);
                }
            }
        }

//+------------------------------------------------------------------+
//| Execute a markrt order.                                          |
//+------------------------------------------------------------------+
        private TradeResult ExecuteMarketOrder(ENUM_BETTER_ORDER_TYPE order_type, double volume, double price, double sl, double tp)
        {
            TradeResult tr = null;
            for (int i = 0; i < Retries; i++)
            {
                TradeType tt = TradeType.Buy;
                if (order_type == ENUM_BETTER_ORDER_TYPE.Sell) tt = TradeType.Sell;
                tr = ExecuteMarketRangeOrder(tt, Symbol.Name, volume, Slippage, price, Commentary, sl, tp, Commentary);
                
                if (!tr.IsSuccessful)
                {
                    Print("Error sending order: " + tr.Error + ".");
                    Print("Volume = " + volume.ToString() + " Entry = " + price.ToString() + " SL = " + sl.ToString() + " TP = " + tp.ToString());
                }
                else
                {
                    Print("Order executed. Position: " + tr.Position.Id.ToString() + ".");
                    break;
                }
            }
            
            if (!tr.IsSuccessful)
            {
                Print("Execution failed after " + Retries.ToString() + " tries.");
            }
        
            return tr;
        }

//+------------------------------------------------------------------+
//| Create a pending order.                                          |
//+------------------------------------------------------------------+
        private TradeResult CreatePendingOrder(ENUM_BETTER_ORDER_TYPE order_type, double volume, double price, double sl, double tp)
        {
            TradeResult tr = null;
            for (int i = 0; i < Retries; i++)
            {
                TradeType tt = TradeType.Buy;
                if ((order_type == ENUM_BETTER_ORDER_TYPE.Sell_Stop) || (order_type == ENUM_BETTER_ORDER_TYPE.Sell_Limit)) tt = TradeType.Sell;
                
                // Stop order
                if ((order_type == ENUM_BETTER_ORDER_TYPE.Buy_Stop) || (order_type == ENUM_BETTER_ORDER_TYPE.Sell_Stop))
                {
                    if (expires_time != unix_epoch) tr = PlaceStopOrder(tt, Symbol.Name, volume, price, Commentary, sl, tp, expires_time, Commentary);
                    else tr = PlaceStopOrder(tt, Symbol.Name, volume, price, Commentary, sl, tp, null, Commentary);
                }
                // Limit order
                else
                {
                    if (expires_time != unix_epoch) tr = PlaceLimitOrder(tt, Symbol.Name, volume, price, Commentary, sl, tp, expires_time, Commentary);
                    else tr = PlaceLimitOrder(tt, Symbol.Name, volume, price, Commentary, sl, tp, null, Commentary);
                }
                if (!tr.IsSuccessful)
                {
                    Print("Error Sending " + order_type.ToString() + ": " + tr.Error);
                    Print("Volume = " + volume.ToString() + " Entry = " + price.ToString() + " SL = " + sl.ToString() + " TP = " + tp.ToString());
                }
                else
                {
                    Print("Order created. Ticket: " + tr.PendingOrder.Id.ToString() + ".");
                    break;
                }
            }
            
            if (!tr.IsSuccessful)
            {
                Print("Creation failed after " + Retries.ToString() + " tries.");
            }
        
            return tr;
        }

//+------------------------------------------------------------------+
//| Format time distance from the number of seconds to normal string |
//| of years, days, hours, minutes, and seconds. 					 |
//| t - time difference								 			     |
//| Returns: formatted string.		 								 |
//+------------------------------------------------------------------+
        string TimeDistance(TimeSpan t)
        {
            if ((t < TimeSpan.FromSeconds(1)) && (t > TimeSpan.FromSeconds(1).Negate()))
                return (" 0 seconds");
            string s = "";
            int d = t.Days;
            int h = t.Hours;
            int m = t.Minutes;
            int sec = t.Seconds;

            if (d > 0)
                s += " " + d.ToString() + " day";
            if (d > 1)
                s += "s";

            if (h > 0)
                s += " " + h.ToString() + " hour";
            if (h > 1)
                s += "s";

            if (m > 0)
                s += " " + m.ToString() + " minute";
            if (m > 1)
                s += "s";

            if (sec > 0)
                s += " " + sec.ToString() + " second";
            if (sec > 1)
                s += "s";

            return s;
        }

//+------------------------------------------------------------------+
//| Calculate position size depending on money management parameters.|
//+------------------------------------------------------------------+
        double GetPositionSize
        (double SL)
        {
            if (!CalculatePositionSize)
                return (Symbol.QuantityToVolumeInUnits(FixedPositionSize));

            double Size, RiskMoney, PositionSize = 0;

            if (Account.Asset.Name == "")
                return (0);

            if (FixedBalance > 0)
            {
                Size = FixedBalance;
            }
            else if (UseEquityInsteadOfBalance)
            {
                Size = Account.Equity;
            }
            else
            {
                Size = Account.Balance;
            }

            if (!UseMoneyInsteadOfPercentage)
                RiskMoney = Size * Risk / 100;
            else
                RiskMoney = MoneyRisk;

            double UnitCost = Symbol.PipValue;

            if ((SL != 0) && (UnitCost != 0))
                PositionSize = (int)Math.Round(RiskMoney / SL / UnitCost);

            if (PositionSize < Symbol.VolumeInUnitsMin)
            {
                Print("Calculated position size (" + PositionSize + ") is less than minimum position size (" + Symbol.VolumeInUnitsMin + "). Setting position size to minimum.");
                PositionSize = Symbol.VolumeInUnitsMin;
            }
            else if (PositionSize > Symbol.VolumeInUnitsMax)
            {
                Print("Calculated position size (" + PositionSize + ") is greater than maximum position size (" + Symbol.VolumeInUnitsMax + "). Setting position size to maximum.");
                PositionSize = Symbol.VolumeInUnitsMax;
            }

            double LotStep = Symbol.VolumeInUnitsStep;
            double steps = PositionSize / LotStep;
            if (Math.Floor(steps) < steps)
            {
                Print("Calculated position size (" + PositionSize + ") uses uneven step size. Allowed step size = " + LotStep + ". Setting position size to " + (Math.Floor(steps) * LotStep) + ".");
                PositionSize = Math.Floor(steps) * LotStep;
            }

            return PositionSize;
        }

// Checks whether input parameters make sense and returns error if they don't.
        string CheckInputParameters()
        {
            if (!DailyMode) // Normal mode (one-time fixed-date trade).
            {
                // Order time has already passed.
                if (((TimeType == ENUM_TIME_TYPE.Server) && (trade_time <= Time)) || ((TimeType == ENUM_TIME_TYPE.Local) && (trade_time <= DateTime.Now))) return "Order time has already passed.";
            }
            else // Daily mode (trades every set day at a given time).
            {
                if ((!Monday) && (!Tuesday) && (!Wednesday) && (!Thursday) && (!Friday) && (!Saturday) && (!Sunday)) return "At least one day of the week should be selected.";
            }
            // Pending order with zero entry.
            if ((OrderType != ENUM_BETTER_ORDER_TYPE.Buy) && (OrderType != ENUM_BETTER_ORDER_TYPE.Sell) && (Entry == 0) && (EntryDistancePoints <= 0)) return "Entry price and distance cannot be both zero for pending orders.";
           
            // SL on the wrong side.
            if ((StopLoss != 0) && (SLType == ENUM_SLTP_TYPE.Price_Level) && (EntryDistancePoints <= 0))
            {
                if (StopLoss >= Entry)
                {
                    if (OrderType == ENUM_BETTER_ORDER_TYPE.Buy_Stop) return "Stop-loss cannot be above entry for a Buy Stop.";
                    if (OrderType == ENUM_BETTER_ORDER_TYPE.Buy_Limit) return "Stop-loss cannot be above entry for a Buy Limit.";
                }
                if (StopLoss <= Entry)
                {
                    if (OrderType == ENUM_BETTER_ORDER_TYPE.Sell_Stop) return "Stop-loss cannot be below entry for a Sell Stop.";
                    if (OrderType == ENUM_BETTER_ORDER_TYPE.Sell_Limit) return "Stop-loss cannot be below entry for a Sell Limit.";
                }
            }
            if ((TakeProfit != 0) && (TPType == ENUM_SLTP_TYPE.Price_Level) && (EntryDistancePoints <= 0))
            {
                if (TakeProfit <= Entry)
                {
                    if (OrderType == ENUM_BETTER_ORDER_TYPE.Buy_Stop) return "Take-profit cannot be below entry for a Buy Stop.";
                    if (OrderType == ENUM_BETTER_ORDER_TYPE.Buy_Limit) return "Take-profit cannot be below entry for a Buy Limit.";
                }
                if (TakeProfit >= Entry)
                {
                    if (OrderType == ENUM_BETTER_ORDER_TYPE.Sell_Stop) return "Take-profit cannot be above entry for a Sell Stop.";
                    if (OrderType == ENUM_BETTER_ORDER_TYPE.Sell_Limit) return "Take-profit cannot be above entry for a Sell Limit.";
                }
            }

            double min_lot = Symbol.VolumeInUnitsToQuantity(Symbol.VolumeInUnitsMin);
            double max_lot = Symbol.VolumeInUnitsToQuantity(Symbol.VolumeInUnitsMax);
            double lot_step = Symbol.VolumeInUnitsToQuantity(Symbol.VolumeInUnitsStep);
            Print("Minimum lot: ", min_lot.ToString(), ", lot step: ", lot_step.ToString(), ", maximum lot: ", max_lot.ToString(), ".");
            
            if (!CalculatePositionSize)
            {
                if (FixedPositionSize < min_lot) return "Position size " + FixedPositionSize.ToString() + " < minimum volume " + min_lot.ToString();
                if (FixedPositionSize > max_lot) return "Position size " + FixedPositionSize.ToString() + " > maximum volume " + max_lot.ToString();
                double steps = FixedPositionSize / lot_step;
                if (Math.Floor(steps) < steps) return "Position size " + FixedPositionSize.ToString() + " is not a multiple of lot step " + lot_step.ToString();
            }
            else
            {
                if (StopLoss == 0) return "Cannot calculate position size based on zero stop-loss.";
            }

            if ((expires_time > unix_epoch) && (expires_time < trade_time)) return "Expiration cannot be earlier than order time.";
        
            return "";
        }

// Display various useful information in the chart comment.
        void ShowStatus()
        {
            string s = "Timed Order EA\n";
        
            s += OrderToString(OrderType);
        
            if ((OrderType == ENUM_BETTER_ORDER_TYPE.Buy_Stop) || (OrderType == ENUM_BETTER_ORDER_TYPE.Buy_Limit) || (OrderType == ENUM_BETTER_ORDER_TYPE.Sell_Stop) || (OrderType == ENUM_BETTER_ORDER_TYPE.Sell_Limit))
            {
                if (EntryDistancePoints <= 0) s += " @ " + Entry.ToString();
                else s += " @ " + EntryDistancePoints.ToString() + " pts.";
            }
            
            if (failure) s += "\nExecution failed!";
            if ((!DailyMode) && (trade_done)) // Order already executed or tried to execute.
            {
                if (!failure)
                {
                    s += "\n";
                    s += PostOrderText;
                }
            }
            else if (!failure)
            {
                s += "\n";
                
                if (SLType == ENUM_SLTP_TYPE.Price_Level) s += "SL = " + StopLoss.ToString();
                else if (SLType == ENUM_SLTP_TYPE.Distance) s += "SL = " + ((int)StopLoss).ToString() + " pts.";
                else if (SLType == ENUM_SLTP_TYPE.ATR) s += "SL = " + StopLoss.ToString() + " x ATR(" + ATR_Period.ToString() + ") @ " + ATR_Timeframe.ToString();
                else if (SLType == ENUM_SLTP_TYPE.Spreads) s += "SL = " + StopLoss.ToString() + " spreads";
                
                s += "\n";
                
                if (TPType == ENUM_SLTP_TYPE.Price_Level) s += "TP = " + TakeProfit.ToString();
                else if (TPType == ENUM_SLTP_TYPE.Distance) s += "TP = " + ((int)TakeProfit).ToString() + " pts.";
                else if (TPType == ENUM_SLTP_TYPE.ATR) s += "TP = " + TakeProfit.ToString() + " x ATR(" + ATR_Period.ToString() + ") @ " + ATR_Timeframe.ToString();
                else if (TPType == ENUM_SLTP_TYPE.Spreads) s += "TP = " + TakeProfit.ToString() + " spreads";
            
                s += "\n";
                
                if (!CalculatePositionSize) s += "Pos Size = " + FixedPositionSize.ToString() + " lots";
                else
                {
                    if (UseMoneyInsteadOfPercentage) s += "Risk = " + MoneyRisk.ToString() + " " + Account.Asset.Name;
                    else if (UseEquityInsteadOfBalance) s += "Risk = " + Risk.ToString() + "% of Equity (" + Account.Equity.ToString() + " " + Account.Asset.Name + ")";
                    else if (FixedBalance > 0) s += "Risk = " + Risk.ToString() + "% of " + FixedBalance.ToString() + " " + Account.Asset.Name;
                    else s += "Risk = " + Risk.ToString() + "% of Balance (" + Account.Balance.ToString() + " " + Account.Asset.Name + ")";
                }
            }    
        
            s += "\n";
            
            DateTime order_time = trade_time;
            if (DailyMode) order_time = GetOrderTimeForDailyMode();

            TimeSpan difference;
            if (TimeType == ENUM_TIME_TYPE.Server) difference = Time.Subtract(order_time);
            else difference = DateTime.Now.Subtract(order_time);

            if (difference <= TimeSpan.FromMilliseconds(0))
                s += "Time to order:" + TimeDistance(difference.Negate());
            else
                s += "Time after order:" + TimeDistance(difference);
            
            if (DailyMode)
            {
                if (difference < -TimeSpan.FromSeconds(10)) WillNoLongerTryOpeningTrade = false; // Reset for further order taking.
                s += " (daily mode)";
            }
            s += ".";

            Chart.DrawStaticText("TimedOrder", s, CornerVertical, CornerHorizontal, Color.Red);
        }
        
        string OrderToString(ENUM_BETTER_ORDER_TYPE ot)
        {
            if (ot == ENUM_BETTER_ORDER_TYPE.Buy) return "Buy";
            if (ot == ENUM_BETTER_ORDER_TYPE.Sell) return "Sell";
            if (ot == ENUM_BETTER_ORDER_TYPE.Buy_Limit) return "Buy Limit";
            if (ot == ENUM_BETTER_ORDER_TYPE.Buy_Stop) return "Buy Stop";
            if (ot == ENUM_BETTER_ORDER_TYPE.Sell_Limit) return "Sell Limit";
            if (ot == ENUM_BETTER_ORDER_TYPE.Sell_Stop) return "Sell Stop";
            return "";
        }
        
        DateTime GetOrderTimeForDailyMode()
        {
            bool skip_current_day = false;

            DateTime current_time = DateTime.Now;
            if (TimeType == ENUM_TIME_TYPE.Server) current_time = Time;
            
            DateTime target_time = new DateTime(current_time.Year, current_time.Month, current_time.Day, DailyHour, DailyMinute, DailySecond); // It's important to get the target time of the appropriate day (local/server).

            TimeSpan difference = current_time.Subtract(target_time);
            if (difference > TimeSpan.FromSeconds(10)) skip_current_day = true; // Skip the current day. Give a 10 seconds buffer.
            // Find the next enabled day:
            for (int i = 0; i <= 7; i++, target_time = target_time.AddDays(1)) // <= because the next day could be the same day of the week.
            {
                if ((i == 0) && (skip_current_day))
                {
                    continue;
                }
                if (EnabledDays[(int)target_time.DayOfWeek]) break;
            }
        
            return target_time;
        }
    }
}