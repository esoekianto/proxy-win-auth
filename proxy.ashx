<%@ WebHandler Language="C#" Class="proxy" %>
/*
  This proxy page does not have any security checks. It is highly recommended
  that a user deploying this proxy page on their web server, add appropriate
  security checks, for example checking request path, username/password, target
  url, etc.
*/
using System;
using System.Drawing;
using System.IO;
using System.Web;
using System.Collections.Generic;
using System.Text;
using System.Xml.Serialization;
using System.Web.Caching;
using System.Net;

/// <summary>
/// Forwards requests to an ArcGIS Server REST resource. Uses information in
/// the proxy.config file to determine properties of the server.
/// </summary>
public class proxy : IHttpHandler
{
    ProxyConfig config;

    public proxy()
    {
        config = ProxyConfig.GetCurrentConfig();
    }

    public void ProcessRequest(HttpContext context)
    {
        HttpResponse response = context.Response;

        // Get the URL requested by the client (take the entire querystring at once
        //  to handle the case of the URL itself containing querystring parameters)
        string uri = Uri.UnescapeDataString(context.Request.QueryString.ToString());
        
        // Debug: Ping to make sure avaiable (ie. http://localhost/TestApp/proxy.ashx?ping)
        if (uri.StartsWith("ping"))
        {
            context.Response.Write("Hello proxy");
            return;
        }

        // Get token, if applicable, and append to the request
        string token = config.GetToken(uri);
        System.Net.ICredentials credentials = null;
        
        if (string.IsNullOrEmpty(token))
            token = generateToken(uri);

        if (!string.IsNullOrEmpty(token))
        {
            if (uri.Contains("?"))
                uri += "&token=" + token;
            else
                uri += "?token=" + token;
        }
        else if (!string.IsNullOrEmpty(config.GetUser(uri))) // if using Windows/HTTP authentication
        {
            credentials = getCredentials(uri);
        }

        System.Net.WebRequest req = System.Net.WebRequest.Create(new Uri(uri));
        req.Method = context.Request.HttpMethod;

        // Assign credentials if using Windows/HTTP authentication
        if (credentials != null)
        {
            req.PreAuthenticate = true;
            req.Credentials = credentials;
        }

        // Set body of request for POST requests
        if (context.Request.InputStream.Length > 0)
        {
            byte[] bytes = new byte[context.Request.InputStream.Length];
            context.Request.InputStream.Read(bytes, 0, (int)context.Request.InputStream.Length);
            req.ContentLength = bytes.Length;
            req.ContentType = "application/x-www-form-urlencoded";
            using (Stream outputStream = req.GetRequestStream())
            {
                outputStream.Write(bytes, 0, bytes.Length);
            }
        }

        // Send the request to the server
        System.Net.WebResponse serverResponse = null;
        try
        {
            serverResponse = req.GetResponse();
        }
        catch (System.Net.WebException webExc)
        {
            response.StatusCode = 500;
            response.StatusDescription = webExc.Status.ToString();
            response.Write(webExc.Response);
            response.End();
            return;
        }

        // Set up the response to the client
        if (serverResponse != null)
        {
            response.ContentType = serverResponse.ContentType;
            
            using (Stream byteStream = serverResponse.GetResponseStream())
            {
                byte[] outb = ReadFully(serverResponse.GetResponseStream(), 0);
                response.OutputStream.Write(outb, 0, outb.Length);
                serverResponse.Close();
            }            
        }
        response.End();
    }

    /// <summary>
    /// Reads data from a stream until the end is reached. The
    /// data is returned as a byte array. An IOException is
    /// thrown if any of the underlying IO calls fail.
    /// </summary>
    /// <param name="stream">The stream to read data from</param>
    /// <param name="initialLength">The initial buffer length</param>
    public static byte[] ReadFully(Stream stream, int initialLength)
    {
        // If we've been passed an unhelpful initial length, just
        // use 32K.
        if (initialLength < 1)
        {
            initialLength = 32768;
        }

        byte[] buffer = new byte[initialLength];
        int read = 0;

        int chunk;
        while ((chunk = stream.Read(buffer, read, buffer.Length - read)) > 0)
        {
            read += chunk;

            // If we've reached the end of our buffer, check to see if there's
            // any more information
            if (read == buffer.Length)
            {
                int nextByte = stream.ReadByte();

                // End of stream? If so, we're done
                if (nextByte == -1)
                {
                    return buffer;
                }

                // Nope. Resize the buffer, put in the byte we've just
                // read, and continue
                byte[] newBuffer = new byte[buffer.Length * 2];
                Array.Copy(buffer, newBuffer, buffer.Length);
                newBuffer[read] = (byte)nextByte;
                buffer = newBuffer;
                read++;
            }
        }
        // Buffer is now too big. Shrink it.
        byte[] ret = new byte[read];
        Array.Copy(buffer, ret, read);
        return ret;
    }

    public bool IsReusable
    {
        get
        {
            return false;
        }
    }

    // Gets the token for a server URL from a configuration file
    private string getTokenFromConfigFile(string uri)
    {
        try
        {
            if (config != null)
                return config.GetToken(uri);
            else
                throw new ApplicationException(
                    "Proxy.config file does not exist at application root, or is not readable.");
        }
        catch (InvalidOperationException)
        {
            // Proxy is being used for an unsupported service (proxy.config has mustMatch="true")
            HttpResponse response = HttpContext.Current.Response;
            response.StatusCode = (int)System.Net.HttpStatusCode.Forbidden;
            response.End();
        }
        catch (Exception e)
        {
            if (e is ApplicationException)
                throw e;

            // just return an empty string at this point
            // -- may want to throw an exception, or add to a log file
        }

        return string.Empty;
    }

    public System.Net.ICredentials getCredentials(string url)
    {
        try
        {
            if (config != null)
            {
                foreach (ServerItem si in config.ServerItems)
                    if (url.StartsWith(si.Url, true, null))
                    {
                        string url_401 = url.Substring(0, url.IndexOf("services") + 7);
                        return new NetworkCredential(si.Username, si.Password, si.Domain);
                    }
            }
        }
        catch (InvalidOperationException)
        {
            // Proxy is being used for an unsupported service (proxy.config has mustMatch="true")
            HttpResponse response = HttpContext.Current.Response;
            response.StatusCode = (int)System.Net.HttpStatusCode.Forbidden;
            response.End();
        }
        catch (Exception e)
        {
            if (e is ApplicationException)
                throw e;

            // just return an empty string at this point
            // -- may want to throw an exception, or add to a log file
        }

        return null;
    }

    public string generateToken(string url)
    {
        try
        {
            if (config != null)
            {
                foreach (ServerItem si in config.ServerItems)
                    if (url.StartsWith(si.Url, true, null))
                    {
                        string theToken = null;

                        // If token not available or expired, generate one and store it in cache
                        if (theToken == null)
                        {
                            string tokenServiceUrl = string.Format("{0}?request=getToken&username={1}&password={2}",
                                si.TokenUrl, si.Username, si.Password);

                            int timeout = 60;
                            if (si.Timeout > 0)
                                timeout = si.Timeout;

                            tokenServiceUrl += string.Format("&expiration={0}", timeout);
                            DateTime endTime = DateTime.Now.AddMinutes(timeout);

                            System.Net.WebRequest request = System.Net.WebRequest.Create(tokenServiceUrl);
                            System.Net.WebResponse response = request.GetResponse();
                            System.IO.Stream responseStream = response.GetResponseStream();
                            System.IO.StreamReader readStream = new System.IO.StreamReader(responseStream);
                            theToken = readStream.ReadToEnd();

                            Dictionary<string, object> serverItemEntries = new Dictionary<string, object>();
                            serverItemEntries.Add("token", theToken);
                            serverItemEntries.Add("timeout", endTime);

                            HttpRuntime.Cache.Insert(si.Url, serverItemEntries);
                        }
                        return theToken;
                    }
            }
        }
        catch (InvalidOperationException)
        {
            // Proxy is being used for an unsupported service (proxy.config has mustMatch="true")
            HttpResponse response = HttpContext.Current.Response;
            response.StatusCode = (int)System.Net.HttpStatusCode.Forbidden;
            response.End();
        }
        catch (Exception e)
        {
            if (e is ApplicationException)
                throw e;

            // just return an empty string at this point
            // -- may want to throw an exception, or add to a log file
        }

        return string.Empty;
    }
}

[XmlRoot("ProxyConfig")]
public class ProxyConfig
{
    #region Static Members

    private static object _lockobject = new object();

    public static ProxyConfig LoadProxyConfig(string fileName)
    {
        ProxyConfig config = null;

        lock (_lockobject)
        {
            if (System.IO.File.Exists(fileName))
            {
                XmlSerializer reader = new XmlSerializer(typeof(ProxyConfig));
                using (System.IO.StreamReader file = new System.IO.StreamReader(fileName))
                {
                    config = (ProxyConfig)reader.Deserialize(file);
                }
            }
        }

        return config;
    }

    public static ProxyConfig GetCurrentConfig()
    {
        ProxyConfig config = HttpRuntime.Cache["proxyConfig"] as ProxyConfig;
        if (config == null)
        {
            string fileName = GetFilename(HttpContext.Current);
            config = LoadProxyConfig(fileName);

            if (config != null)
            {
                CacheDependency dep = new CacheDependency(fileName);
                HttpRuntime.Cache.Insert("proxyConfig", config, dep);
            }
        }

        return config;
    }

    // Location of the proxy.config file
    public static string GetFilename(HttpContext context)
    {
        return context.Server.MapPath("proxy.config");
    }
    #endregion

    ServerItem[] serverItems;
    bool mustMatch;

    [XmlArray("serverItems")]
    [XmlArrayItem("serverItem")]
    public ServerItem[] ServerItems
    {
        get { return this.serverItems; }
        set { this.serverItems = value; }
    }

    [XmlAttribute("mustMatch")]
    public bool MustMatch
    {
        get { return mustMatch; }
        set { mustMatch = value; }
    }

    public string GetToken(string uri)
    {
        foreach (ServerItem su in serverItems)
        {
            if (su.MatchAll && uri.StartsWith(su.Url, StringComparison.InvariantCultureIgnoreCase))
            {
                return su.Token;
            }
            else
            {
                if (String.Compare(uri, su.Url, StringComparison.InvariantCultureIgnoreCase) == 0)
                    return su.Token;
            }
        }

        if (mustMatch)
            throw new InvalidOperationException();

        return string.Empty;
    }

    public string GetUser(string uri)
    {
        foreach (ServerItem su in serverItems)
        {
            if (su.MatchAll && uri.StartsWith(su.Url, StringComparison.InvariantCultureIgnoreCase))
            {
                return su.Username;
            }
            else
            {
                if (String.Compare(uri, su.Url, StringComparison.InvariantCultureIgnoreCase) == 0)
                    return su.Username;
            }
        }

        if (mustMatch)
            throw new InvalidOperationException();

        return string.Empty;
    }
}

public class ServerItem
{
    string url;
    bool matchAll;
    string token;
    string tokenUrl;
    string domain;
    string username;
    string password;
    int timeout;

    [XmlAttribute("url")]
    public string Url
    {
        get { return url; }
        set { url = value; }
    }

    [XmlAttribute("matchAll")]
    public bool MatchAll
    {
        get { return matchAll; }
        set { matchAll = value; }
    }

    [XmlAttribute("token")]
    public string Token
    {
        get { return token; }
        set { token = value; }
    }

    [XmlAttribute("tokenUrl")]
    public string TokenUrl
    {
        get { return tokenUrl; }
        set { tokenUrl = value; }
    }

    [XmlAttribute("domain")]
    public string Domain
    {
        get { return domain; }
        set { domain = value; }
    }

    [XmlAttribute("username")]
    public string Username
    {
        get { return username; }
        set { username = value; }
    }

    [XmlAttribute("password")]
    public string Password
    {
        get { return password; }
        set { password = value; }
    }

    [XmlAttribute("timeout")]
    public int Timeout
    {
        get { return timeout; }
        set { timeout = value; }
    }
}

