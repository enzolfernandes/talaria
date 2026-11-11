using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Web.Script.Serialization;
using System.Collections.Generic;

internal static class TestHermes
{
    private static void Main(string[] args)
    {
        if (args.Length == 1 && args[0] == "--version") { Console.WriteLine("Hermes Agent v0.23.0"); return; }
        if (args.Length != 5 || args[0] != "serve" || args[2] != "127.0.0.1") Environment.Exit(2);
        string password = Environment.GetEnvironmentVariable("HERMES_DASHBOARD_BASIC_AUTH_PASSWORD");
        if (String.IsNullOrEmpty(password) && !File.Exists("existing-auth"))
        {
            Console.Error.WriteLine("non-loopback bind now ALWAYS requires an auth provider");
            Environment.Exit(1);
        }
        TcpListener listener = new TcpListener(IPAddress.Parse(args[2]), Int32.Parse(args[4]));
        listener.Start();
        while (true)
        {
            using (TcpClient client = listener.AcceptTcpClient())
            {
                try { Respond(client, password); }
                catch (IOException) { }
            }
        }
    }

    private static void Respond(TcpClient client, string password)
    {
        client.ReceiveTimeout = 3000;
        using (NetworkStream stream = client.GetStream())
        using (StreamReader reader = new StreamReader(stream, Encoding.UTF8))
        {
            string first = reader.ReadLine();
            if (String.IsNullOrEmpty(first)) return;
            string path = first.Split(' ')[1];
            int length = 0;
            bool authenticated = false;
            bool expectContinue = false;
            string header;
            while (!String.IsNullOrEmpty(header = reader.ReadLine()))
            {
                if (header.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))
                    Int32.TryParse(header.Substring(15), out length);
                if (header.StartsWith("Cookie:", StringComparison.OrdinalIgnoreCase)) authenticated = header.Contains("test_auth=valid");
                if (header.StartsWith("Expect:", StringComparison.OrdinalIgnoreCase))
                    expectContinue = header.IndexOf("100-continue", StringComparison.OrdinalIgnoreCase) >= 0;
            }
            if (expectContinue)
            {
                byte[] ready = Encoding.ASCII.GetBytes("HTTP/1.1 100 Continue\r\n\r\n");
                stream.Write(ready, 0, ready.Length);
            }
            char[] requestBody = new char[length];
            if (length != 0 && reader.ReadBlock(requestBody, 0, length) != length) return;
            string body = "{}", cookie = "";
            int status = 200;
            if (path == "/api/health") body = "{\"ok\":true,\"version\":\"0.23.0\",\"auth_required\":true}";
            else if (path == "/api/auth/providers") body = "{\"providers\":[{\"name\":\"basic\",\"supports_password\":true}]}";
            else if (path == "/api/auth/me")
            {
                if (authenticated || File.Exists("unprotected")) body = "{\"provider\":\"basic\"}";
                else status = 401;
            }
            else if (path == "/auth/password-login")
            {
                var input = new JavaScriptSerializer().Deserialize<Dictionary<string, string>>(new String(requestBody));
                if (input["password"] == password)
                {
                    body = "{\"ok\":true}";
                    cookie = "Set-Cookie: test_auth=valid; Path=/\r\n";
                }
                else status = 401;
            }
            else if (path == "/auth/logout") cookie = "Set-Cookie: test_auth=; Path=/; Max-Age=0\r\n";
            else status = 404;
            byte[] bytes = Encoding.UTF8.GetBytes(body);
            string headers = "HTTP/1.1 " + status + " Response\r\nContent-Type: application/json\r\nContent-Length: " + bytes.Length +
                "\r\nConnection: close\r\n" + cookie + "\r\n";
            byte[] prefix = Encoding.ASCII.GetBytes(headers);
            stream.Write(prefix, 0, prefix.Length);
            stream.Write(bytes, 0, bytes.Length);
        }
    }
}
