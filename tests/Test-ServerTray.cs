using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using HermesServerTray;

internal static class ServerTrayTest
{
    private static void Expect(bool condition, string description)
    {
        if (!condition) throw new InvalidOperationException(description);
        Console.WriteLine("PASS " + description);
    }

    private static ProbeResult ProbeResponse(string json)
    {
        TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        Thread responder = new Thread(delegate()
        {
            using (TcpClient client = listener.AcceptTcpClient())
            using (NetworkStream stream = client.GetStream())
            using (StreamReader reader = new StreamReader(stream, Encoding.ASCII))
            {
                client.ReceiveTimeout = 3000;
                string line;
                do { line = reader.ReadLine(); } while (!String.IsNullOrEmpty(line));
                string response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " +
                    Encoding.UTF8.GetByteCount(json) + "\r\nConnection: close\r\n\r\n" + json;
                byte[] bytes = Encoding.UTF8.GetBytes(response);
                stream.Write(bytes, 0, bytes.Length);
            }
        });
        responder.IsBackground = true;
        responder.Start();
        try { return HealthProbe.Check(new Uri("http://127.0.0.1:" + port)); }
        finally { responder.Join(3500); listener.Stop(); }
    }

    private static void CheckIconRecovery()
    {
        Queue<IconCommand> commands = new Queue<IconCommand>(new[] {
            IconCommand.Modify, IconCommand.Add, IconCommand.Delete, IconCommand.Add, IconCommand.SetVersion
        });
        Queue<bool> results = new Queue<bool>(new[] { false, false, true, true, true });
        bool version4 = false;
        bool registered = TrayWindow.PublishIcon(delegate(IconCommand command)
        {
            if (commands.Dequeue() != command) throw new InvalidOperationException("Unexpected icon recovery command");
            return results.Dequeue();
        }, false, ref version4);
        Expect(registered && version4 && commands.Count == 0, "a stale Explorer icon is replaced and uses version 4 callbacks");

        commands = new Queue<IconCommand>(new[] { IconCommand.Modify, IconCommand.SetVersion });
        registered = TrayWindow.PublishIcon(delegate(IconCommand command)
        {
            if (commands.Dequeue() != command) throw new InvalidOperationException("Unexpected icon update command");
            return true;
        }, false, ref version4);
        Expect(registered && commands.Count == 0, "an icon Explorer still owns can be updated without being replaced");
    }

    private static void Main()
    {
        ProbeResult live = ProbeResponse("{\"ok\":true,\"version\":\"0.23.0\"}");
        Expect(live.Kind == ProbeKind.Healthy, "Hermes health response");
        ProbeResult invalid = ProbeResponse("{\"ok\":true,\"other\":\"service\"}");
        Expect(invalid.Kind == ProbeKind.Failed, "unrelated HTTP 200 is rejected");
        ProbeResult missing = HealthProbe.Check(new Uri("http://192.0.2.1:9119"));
        Expect(missing.Kind == ProbeKind.MissingAddress, "missing local address is detected");
        StatusTracker tracker = new StatusTracker();
        Expect(tracker.CheckIntervalSeconds == 15, "startup uses the 15-second retry interval");
        tracker.Apply(live);
        Expect(tracker.State == TrayState.Online, "healthy response shows green");
        Expect(tracker.CheckIntervalSeconds == 300, "online status checks every five minutes");
        tracker.Apply(invalid);
        tracker.Apply(invalid);
        Expect(tracker.State == TrayState.Waiting, "transient failures show yellow");
        tracker.Apply(invalid);
        Expect(tracker.State == TrayState.Offline, "three consecutive failures show red");
        Expect(tracker.CheckIntervalSeconds == 15, "offline status checks every 15 seconds");
        tracker.Apply(missing);
        Expect(tracker.State == TrayState.Waiting && tracker.Failures == 0, "waiting for Tailscale shows yellow");
        tracker.Apply(live);
        Expect(tracker.State == TrayState.Online && tracker.Failures == 0, "recovery returns to green");
        CheckIconRecovery();
    }
}
