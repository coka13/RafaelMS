package net.server.web;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpServer;
import config.YamlConfig;
import tools.BCrypt;
import tools.DatabaseConnection;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.UnsupportedEncodingException;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.HashMap;
import java.util.Iterator;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.regex.Pattern;

/**
 * Small HTTP server for the account registration page.
 *
 * The client (Ezorsia dinput8.dll) opens http://&lt;ServerIP_Address&gt;/register.html from the
 * login screen's Register/Homepage buttons. This serves the files in the "web" folder
 * (register.html, bg.jpg, ...) and handles POST /register, which creates the account.
 */
public final class RegisterWebServer {

    private static final Pattern NAME = Pattern.compile("^[A-Za-z0-9]{4,12}$");
    private static final Pattern EMAIL = Pattern.compile("^[^@\\s]{1,64}@[^@\\s]{1,64}\\.[^@\\s]{2,}$");
    private static final int MAX_BODY = 4096;
    private static final long WINDOW_MS = 60L * 60L * 1000L;      // 1 hour
    private static final int MAX_ACCOUNTS_PER_WINDOW = 3;           // per IP
    private static final int MAX_ATTEMPTS_PER_WINDOW = 30;          // per IP, successful or not

    private static final Map<String, String> MIME = new HashMap<>();
    static {
        MIME.put("html", "text/html; charset=utf-8");
        MIME.put("css", "text/css; charset=utf-8");
        MIME.put("js", "application/javascript; charset=utf-8");
        MIME.put("jpg", "image/jpeg");
        MIME.put("jpeg", "image/jpeg");
        MIME.put("png", "image/png");
        MIME.put("gif", "image/gif");
        MIME.put("ico", "image/x-icon");
        MIME.put("svg", "image/svg+xml");
        MIME.put("webp", "image/webp");
    }

    private static HttpServer server;
    private static final Map<String, Deque<Long>> created = new ConcurrentHashMap<>();
    private static final Map<String, Deque<Long>> attempts = new ConcurrentHashMap<>();

    private RegisterWebServer() {}

    public static synchronized void start() {
        if (server != null || !YamlConfig.config.server.WEB_REGISTER) return;

        int port = YamlConfig.config.server.WEB_PORT > 0 ? YamlConfig.config.server.WEB_PORT : 80;
        File root = new File(System.getProperty("webpath", "web"));
        try {
            server = HttpServer.create(new InetSocketAddress(port), 0);
            // one context: HttpServer matches contexts by prefix, so "/register" would also catch "/register.html"
            final HttpHandler register = new RegisterHandler();
            final HttpHandler files = new StaticHandler(root.getCanonicalFile());
            server.createContext("/", ex -> {
                if ("/register".equals(ex.getRequestURI().getPath())) register.handle(ex);
                else files.handle(ex);
            });
            server.setExecutor(Executors.newFixedThreadPool(4));
            server.start();
            System.out.println("Registration page on http://" + YamlConfig.config.server.HOST
                    + (port == 80 ? "" : ":" + port) + "/register.html");
        } catch (IOException e) {
            server = null;
            System.out.println("Could not start the registration web server on port " + port + ": " + e.getMessage()
                    + " (is another program such as IIS, Skype or a web server using it? Change WEB_PORT in config.yaml)");
        }
    }

    public static synchronized void stop() {
        if (server != null) {
            server.stop(0);
            server = null;
        }
    }

    /* ------------------------------------------------------------------ static files */

    private static final class StaticHandler implements HttpHandler {
        private final File root;

        StaticHandler(File root) {
            this.root = root;
        }

        @Override
        public void handle(HttpExchange ex) throws IOException {
            try {
                String method = ex.getRequestMethod();
                if (!"GET".equals(method) && !"HEAD".equals(method)) {
                    send(ex, 405, "text/plain; charset=utf-8", "Method not allowed");
                    return;
                }
                String path = ex.getRequestURI().getPath();
                if (path == null || path.equals("/") || path.isEmpty()) path = "/register.html";

                File f = new File(root, URLDecoder.decode(path, "UTF-8")).getCanonicalFile();
                if (!f.getPath().startsWith(root.getPath() + File.separator) || !f.isFile()) {
                    send(ex, 404, "text/plain; charset=utf-8", "Not found");
                    return;
                }
                String name = f.getName();
                String ext = name.lastIndexOf('.') >= 0 ? name.substring(name.lastIndexOf('.') + 1).toLowerCase() : "";
                String type = MIME.get(ext);
                if (type == null) {
                    send(ex, 404, "text/plain; charset=utf-8", "Not found");
                    return;
                }
                byte[] data = Files.readAllBytes(f.toPath());
                ex.getResponseHeaders().set("Cache-Control", "html".equals(ext) ? "no-cache" : "max-age=3600");
                send(ex, 200, type, data, "HEAD".equals(method));
            } catch (IllegalArgumentException e) {
                send(ex, 400, "text/plain; charset=utf-8", "Bad request");
            } finally {
                ex.close();
            }
        }
    }

    /* ------------------------------------------------------------------ registration */

    private static final class RegisterHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange ex) throws IOException {
            try {
                if (!"POST".equals(ex.getRequestMethod())) {
                    json(ex, 405, false, "Use the form on the registration page.");
                    return;
                }
                String ip = ex.getRemoteAddress().getAddress().getHostAddress();
                if (!allow(attempts, ip, MAX_ATTEMPTS_PER_WINDOW)) {
                    json(ex, 429, false, "Too many attempts. Please try again later.");
                    return;
                }

                byte[] raw = readBody(ex.getRequestBody());
                if (raw == null) {
                    json(ex, 413, false, "Request too large.");
                    return;
                }
                Map<String, String> form = parseForm(new String(raw, StandardCharsets.UTF_8));
                String name = form.getOrDefault("username", "").trim();
                String pass = form.getOrDefault("password", "");
                String confirm = form.getOrDefault("confirm", "");
                String email = form.getOrDefault("email", "").trim();

                if (!NAME.matcher(name).matches()) {
                    json(ex, 400, false, "Username must be 4-12 letters or numbers.");
                    return;
                }
                if (pass.length() < 6 || pass.length() > 12) {
                    json(ex, 400, false, "Password must be 6-12 characters.");
                    return;
                }
                for (char ch : pass.toCharArray()) {
                    if (ch < 0x21 || ch > 0x7E) {
                        json(ex, 400, false, "Password can only use letters, numbers and symbols (no spaces).");
                        return;
                    }
                }
                if (!pass.equals(confirm)) {
                    json(ex, 400, false, "Passwords do not match.");
                    return;
                }
                if (!email.isEmpty() && (email.length() > 45 || !EMAIL.matcher(email).matches())) {
                    json(ex, 400, false, "Please enter a valid e-mail address, or leave it empty.");
                    return;
                }
                if (!peek(created, ip, MAX_ACCOUNTS_PER_WINDOW)) {
                    json(ex, 429, false, "You created too many accounts. Please try again later.");
                    return;
                }

                int result = createAccount(name, pass, email.isEmpty() ? null : email);
                if (result == 1) {
                    allow(created, ip, MAX_ACCOUNTS_PER_WINDOW);
                    System.out.println("Web registration: account '" + name + "' created from " + ip);
                    json(ex, 200, true, "Account " + name + " created! You can now log in.");
                } else if (result == 0) {
                    json(ex, 409, false, "That username is already taken.");
                } else {
                    json(ex, 500, false, "Server error. Please try again later.");
                }
            } finally {
                ex.close();
            }
        }
    }

    /** @return 1 created, 0 name taken, -1 error */
    private static int createAccount(String name, String pass, String email) {
        Connection con = null;
        PreparedStatement ps = null;
        ResultSet rs = null;
        try {
            con = DatabaseConnection.getConnection();
            ps = con.prepareStatement("SELECT id FROM accounts WHERE name = ?");
            ps.setString(1, name);
            rs = ps.executeQuery();
            if (rs.next()) return 0;
            rs.close();
            rs = null;
            ps.close();

            // webregistered = 1: only these accounts may log in when WEB_REGISTER_REQUIRED is on
            ps = con.prepareStatement("INSERT INTO accounts (name, password, birthday, tempban, email, webregistered) VALUES (?, ?, ?, ?, ?, 1)");
            ps.setString(1, name);
            ps.setString(2, BCrypt.hashpw(pass, BCrypt.gensalt(12)));
            ps.setString(3, "2018-06-20");   // same placeholders as AUTOMATIC_REGISTER (MySQL strict mode)
            ps.setString(4, "2018-06-20");
            ps.setString(5, email);
            ps.executeUpdate();
            return 1;
        } catch (SQLException e) {
            if (e.getErrorCode() == 1062) return 0;   // duplicate key (raced with another request)
            e.printStackTrace();
            return -1;
        } finally {
            try { if (rs != null) rs.close(); } catch (SQLException ignored) {}
            try { if (ps != null) ps.close(); } catch (SQLException ignored) {}
            try { if (con != null) con.close(); } catch (SQLException ignored) {}
        }
    }

    /* ------------------------------------------------------------------ helpers */

    private static boolean peek(Map<String, Deque<Long>> map, String ip, int max) {
        Deque<Long> q = map.get(ip);
        if (q == null) return true;
        synchronized (q) {
            prune(q, System.currentTimeMillis());
            return q.size() < max;
        }
    }

    private static boolean allow(Map<String, Deque<Long>> map, String ip, int max) {
        long now = System.currentTimeMillis();
        if (map.size() > 10000) {   // keep memory bounded
            for (Iterator<Deque<Long>> it = map.values().iterator(); it.hasNext(); ) {
                Deque<Long> q = it.next();
                synchronized (q) {
                    prune(q, now);
                    if (q.isEmpty()) it.remove();
                }
            }
        }
        Deque<Long> q = map.computeIfAbsent(ip, k -> new ArrayDeque<>());
        synchronized (q) {
            prune(q, now);
            if (q.size() >= max) return false;
            q.addLast(now);
            return true;
        }
    }

    private static void prune(Deque<Long> q, long now) {
        while (!q.isEmpty() && now - q.peekFirst() > WINDOW_MS) q.pollFirst();
    }

    private static byte[] readBody(InputStream in) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[1024];
        int n;
        while ((n = in.read(buf)) != -1) {
            out.write(buf, 0, n);
            if (out.size() > MAX_BODY) return null;
        }
        return out.toByteArray();
    }

    private static Map<String, String> parseForm(String body) throws UnsupportedEncodingException {
        Map<String, String> map = new HashMap<>();
        for (String pair : body.split("&")) {
            if (pair.isEmpty()) continue;
            int eq = pair.indexOf('=');
            try {
                String k = URLDecoder.decode(eq < 0 ? pair : pair.substring(0, eq), "UTF-8");
                String v = eq < 0 ? "" : URLDecoder.decode(pair.substring(eq + 1), "UTF-8");
                map.put(k, v);
            } catch (IllegalArgumentException ignored) {}
        }
        return map;
    }

    private static void json(HttpExchange ex, int code, boolean ok, String message) throws IOException {
        String body = "{\"ok\":" + ok + ",\"message\":\"" + message.replace("\\", "\\\\").replace("\"", "\\\"") + "\"}";
        send(ex, code, "application/json; charset=utf-8", body);
    }

    private static void send(HttpExchange ex, int code, String type, String body) throws IOException {
        send(ex, code, type, body.getBytes(StandardCharsets.UTF_8), false);
    }

    private static void send(HttpExchange ex, int code, String type, byte[] data, boolean headOnly) throws IOException {
        ex.getResponseHeaders().set("Content-Type", type);
        ex.getResponseHeaders().set("X-Content-Type-Options", "nosniff");
        if (headOnly) {
            ex.sendResponseHeaders(code, -1);
            return;
        }
        ex.sendResponseHeaders(code, data.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(data);
        }
    }
}
