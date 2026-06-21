using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Windows.ApplicationModel.Activation;
using Windows.ApplicationModel.Background;
using Windows.Storage;
using Windows.UI.Notifications;

namespace Unigram.Common
{
    public class Toast
    {
        /// <summary>
        /// In-process background task that periodically wakes TDLib to fetch and show
        /// notifications, since Windows 10 Mobile no longer receives Telegram WNS pushes.
        /// </summary>
        public const string RefreshTaskName = "RefreshTask";

        private const string RefreshIntervalKey = "BackgroundRefreshInterval";
        private const uint DefaultRefreshInterval = 15;

        /// <summary>
        /// Valid background refresh intervals, in minutes. 0 means "Off".
        /// 15 is the platform minimum for <see cref="TimeTrigger"/>.
        /// </summary>
        public static readonly uint[] RefreshIntervals = { 0, 15, 30, 60 };

        /// <summary>
        /// The configured background refresh interval in minutes (0 = Off).
        /// </summary>
        public static uint BackgroundRefreshInterval
        {
            get
            {
                if (ApplicationData.Current.LocalSettings.Values.TryGetValue(RefreshIntervalKey, out object value) && value is int minutes && minutes >= 0)
                {
                    return (uint)minutes;
                }

                return DefaultRefreshInterval;
            }
            set
            {
                ApplicationData.Current.LocalSettings.Values[RefreshIntervalKey] = (int)value;
            }
        }

        public static async Task RegisterBackgroundTasks()
        {
            try
            {
                //BackgroundExecutionManager.RemoveAccess();

                foreach (var t in BackgroundTaskRegistration.AllTasks)
                {
                    if (t.Value.Name == "NotificationTask" || t.Value.Name == "NewNotificationTask")
                    {
                        t.Value.Unregister(false);
                    }
                }

                var access = await BackgroundExecutionManager.RequestAccessAsync();
                if (access == BackgroundAccessStatus.DeniedByUser || access == BackgroundAccessStatus.DeniedBySystemPolicy)
                {
                    return;
                }

                Register("InProcessNotificationTask", null, () => new PushNotificationTrigger());
                //Register("NewNotificationTask2", null, () => new PushNotificationTrigger());
                Register("NewInteractiveTask", null, () => new ToastNotificationActionTrigger());
                //BackgroundTaskManager.Register("InteractiveTask", "Unigram.Tasks.InteractiveTask", new ToastNotificationActionTrigger());

                RegisterRefreshTask();
            }
            catch { }
        }

        /// <summary>
        /// (Re)registers the periodic refresh task to match <see cref="BackgroundRefreshInterval"/>.
        /// Call this after changing the interval to apply it immediately. When the interval is 0
        /// the task is unregistered.
        /// </summary>
        public static void RegisterRefreshTask()
        {
            try
            {
                var interval = BackgroundRefreshInterval;

                BackgroundTaskRegistration existing = null;
                foreach (var t in BackgroundTaskRegistration.AllTasks)
                {
                    if (t.Value.Name == RefreshTaskName)
                    {
                        existing = t.Value as BackgroundTaskRegistration;
                        break;
                    }
                }

                // Always unregister first: the interval may have changed and the
                // existing registration's period can't be read back to compare.
                existing?.Unregister(true);

                if (interval == 0)
                {
                    return;
                }

                var builder = new BackgroundTaskBuilder
                {
                    Name = RefreshTaskName
                };

                builder.SetTrigger(new TimeTrigger(interval, false));
                builder.AddCondition(new SystemCondition(SystemConditionType.InternetAvailable));
                builder.Register();
            }
            catch { }
        }

        private static bool Register(string name, string entryPoint, Func<IBackgroundTrigger> trigger, Action onCompleted = null)
        {
            //var access = await BackgroundExecutionManager.RequestAccessAsync();
            //if (access == BackgroundAccessStatus.DeniedByUser || access == BackgroundAccessStatus.DeniedBySystemPolicy)
            //{
            //    return false;
            //}
            try
            {
                foreach (var t in BackgroundTaskRegistration.AllTasks)
                {
                    if (t.Value.Name == name)
                    {
                        //t.Value.Unregister(false);
                        return false;
                    }
                }

                var builder = new BackgroundTaskBuilder();
                builder.Name = name;

                if (entryPoint != null)
                {
                    builder.TaskEntryPoint = entryPoint;
                }

                builder.SetTrigger(trigger());

                var registration = builder.Register();
                if (onCompleted != null)
                {
                    registration.Completed += (s, a) =>
                    {
                        onCompleted();
                    };
                }

                return true;
            }
            catch
            {
                return false;
            }
        }

        public static int? GetSession(IActivatedEventArgs args)
        {
            string arguments = null;

            switch (args)
            {
                case ToastNotificationActivatedEventArgs toastNotification:
                    arguments = toastNotification.Argument;
                    break;
                case LaunchActivatedEventArgs launch:
                    if (launch.TileActivatedInfo != null && launch.TileActivatedInfo.RecentlyShownNotifications.Count > 0)
                    {
                        arguments = launch.TileActivatedInfo.RecentlyShownNotifications[0].Arguments;
                    }
                    break;
                case ProtocolActivatedEventArgs protocol:
                    var uri = protocol.Uri.ToString();
                    break;
            }

            var data = SplitArguments(arguments);
            if (data.TryGetValue("session", out string value) && int.TryParse(value, out int result))
            {
                // TODO: move additional checks here
                return result;
            }

            return null;
        }

        public static Dictionary<string, string> GetData(IActivatedEventArgs args)
        {
            if (args.Kind == ActivationKind.ToastNotification)
            {
                ToastNotificationActivatedEventArgs toastActivationArgs = args as ToastNotificationActivatedEventArgs;

                var dictionary = SplitArguments(toastActivationArgs.Argument);
                if (toastActivationArgs.UserInput != null && toastActivationArgs.UserInput.Count > 0)
                {
                    for (int i = 0; i < toastActivationArgs.UserInput.Count; i++)
                    {
                        dictionary.Add(toastActivationArgs.UserInput.Keys.ElementAt(i), toastActivationArgs.UserInput.Values.ElementAt(i).ToString());
                    }
                }

                return dictionary;
            }

            return null;
        }

        public static Dictionary<string, string> GetData(IBackgroundTaskInstance args)
        {
            if (args.TriggerDetails is ToastNotificationActionTriggerDetail)
            {
                ToastNotificationActionTriggerDetail details = args.TriggerDetails as ToastNotificationActionTriggerDetail;
                if (details == null)
                {
                    return null;
                }

                var dictionary = SplitArguments(details.Argument);
                if (details.UserInput != null && details.UserInput.Count > 0)
                {
                    for (int i = 0; i < details.UserInput.Count; i++)
                    {
                        dictionary.Add(details.UserInput.Keys.ElementAt(i), details.UserInput.Values.ElementAt(i).ToString());
                    }
                }

                return dictionary;
            }

            return null;
        }

        public static Dictionary<string, string> GetData(ToastNotificationActionTriggerDetail triggerDetail)
        {
            var dictionary = SplitArguments(triggerDetail.Argument);
            if (triggerDetail.UserInput != null && triggerDetail.UserInput.Count > 0)
            {
                foreach (var input in triggerDetail.UserInput)
                {
                    dictionary[input.Key] = input.Value.ToString();
                }
            }

            return dictionary;
        }

        public static Dictionary<string, string> SplitArguments(string arguments)
        {
            var dictionary = new Dictionary<string, string>();
            if (arguments == null || arguments == string.Empty || !arguments.Contains("="))
            {
                return dictionary;
            }

            string[] items = arguments.Split('&');
            foreach (string item in items)
            {
                string[] pair = item.Split('=');
                dictionary.Add(pair[0], pair[1]);
            }

            return dictionary;
        }
    }
}
