using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Telegram.Td.Api;
using Unigram.Views;

namespace Unigram.Services
{
    /// <summary>
    /// Drives a periodic, local notification refresh.
    ///
    /// Windows 10 Mobile no longer receives Telegram pushes over WNS, so instead of
    /// relying on a real-time push channel this service is invoked from a periodic
    /// background <c>TimeTrigger</c> (see <see cref="Unigram.Common.Toast"/>). When the
    /// app process is launched for the trigger, the <see cref="App"/> constructor has
    /// already built every session container and auto-activated each
    /// <see cref="NotificationsService"/>, so TDLib is already coming online. This
    /// service simply makes sure each session is initialized and then keeps the
    /// background deferral alive until TDLib has finished delivering its pending
    /// notifications (which <see cref="NotificationsService"/> turns into toasts).
    /// </summary>
    public static class BackgroundSyncService
    {
        // Grace period after a session reports no more pending notifications, to let
        // NotificationsService emit the toasts for whatever just arrived.
        private static readonly TimeSpan Settle = TimeSpan.FromSeconds(3);

        /// <summary>
        /// Wakes every signed-in session and waits, up to <paramref name="budget"/>,
        /// for TDLib to deliver any pending notifications.
        /// </summary>
        public static async Task SyncAsync(TimeSpan budget, CancellationToken cancellationToken = default)
        {
            var sessions = TLContainer.Current.Lifetime.Items.ToList();
            if (sessions.Count == 0)
            {
                return;
            }

            var monitors = new List<NotificationMonitor>();

            foreach (var session in sessions)
            {
                var protoService = TLContainer.Current.Resolve<IProtoService>(session.Id);
                var aggregator = TLContainer.Current.Resolve<IEventAggregator>(session.Id);
                if (protoService == null || aggregator == null)
                {
                    continue;
                }

                // No-op if the session is already running (the active session usually is).
                protoService.TryInitialize();

                var monitor = new NotificationMonitor(protoService, aggregator);
                monitor.Start();
                monitors.Add(monitor);
            }

            if (monitors.Count == 0)
            {
                return;
            }

            try
            {
                var completion = Task.WhenAll(monitors.Select(x => x.Completion));
                await Task.WhenAny(completion, Task.Delay(budget, cancellationToken));
            }
            catch (OperationCanceledException) { }
            finally
            {
                foreach (var monitor in monitors)
                {
                    monitor.Stop();
                }
            }
        }

        /// <summary>
        /// Watches a single session for connection readiness and pending-notification
        /// state, completing once TDLib has connected and drained its notifications.
        /// </summary>
        private sealed class NotificationMonitor : IHandle<UpdateHavePendingNotifications>, IHandle<UpdateConnectionState>
        {
            private readonly IProtoService _protoService;
            private readonly IEventAggregator _aggregator;
            private readonly TaskCompletionSource<bool> _completion = new TaskCompletionSource<bool>();
            private readonly object _lock = new object();

            private bool _connected;
            private bool _pending = true; // assume we still need to sync until TDLib says otherwise
            private CancellationTokenSource _settleCts;

            public NotificationMonitor(IProtoService protoService, IEventAggregator aggregator)
            {
                _protoService = protoService;
                _aggregator = aggregator;
            }

            public Task Completion => _completion.Task;

            public void Start()
            {
                _aggregator.Subscribe(this);

                if (_protoService.GetConnectionState() is ConnectionStateReady)
                {
                    _connected = true;
                }

                // A logged-out session will never produce notifications, so don't block on it.
                var state = _protoService.GetAuthorizationState();
                if (state != null && !(state is AuthorizationStateReady))
                {
                    _completion.TrySetResult(true);
                }
            }

            public void Stop()
            {
                _aggregator.Unsubscribe(this);
                CancelSettle();
                _completion.TrySetResult(true);
            }

            public void Handle(UpdateConnectionState update)
            {
                if (update.State is ConnectionStateReady)
                {
                    _connected = true;
                    TryScheduleCompletion();
                }
            }

            public void Handle(UpdateHavePendingNotifications update)
            {
                _pending = update.HaveDelayedNotifications || update.HaveUnreceivedNotifications;
                if (_pending)
                {
                    CancelSettle();
                }
                else
                {
                    TryScheduleCompletion();
                }
            }

            private void TryScheduleCompletion()
            {
                if (_connected && !_pending)
                {
                    ScheduleCompletion();
                }
            }

            private void ScheduleCompletion()
            {
                lock (_lock)
                {
                    _settleCts?.Cancel();
                    _settleCts = new CancellationTokenSource();
                    var token = _settleCts.Token;

                    _ = Task.Delay(Settle, token).ContinueWith(task =>
                    {
                        if (!task.IsCanceled)
                        {
                            _completion.TrySetResult(true);
                        }
                    }, TaskScheduler.Default);
                }
            }

            private void CancelSettle()
            {
                lock (_lock)
                {
                    _settleCts?.Cancel();
                    _settleCts = null;
                }
            }
        }
    }
}
