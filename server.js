const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 3000;
const DATA_FILE = '/data/rates.json';

// Basic Authentication credentials
const AUTH_USERNAME = process.env.AUTH_USERNAME || 'admin';
const AUTH_PASSWORD = process.env.AUTH_PASSWORD || 'admin@111';

// Default configuration (fixed 3 meters)
const DEFAULT_CONFIG = {
    flow_meters: [
        {
            id: 1,
            name: "العداد الأول",
            target_liters: 0.200,
            unit: "L"
        },
        {
            id: 2,
            name: "العداد الثاني",
            target_liters: 0.350,
            unit: "L"
        },
        {
            id: 3,
            name: "العداد الثالث",
            target_liters: 0.500,
            unit: "L"
        }
    ],
    last_updated: new Date().toISOString(),
    version: "1.0"
};

// Ensure data directory exists and load/create config
function initConfig() {
    const dataDir = path.dirname(DATA_FILE);
    if (!fs.existsSync(dataDir)) {
        fs.mkdirSync(dataDir, { recursive: true });
    }
    
    if (!fs.existsSync(DATA_FILE)) {
        fs.writeFileSync(DATA_FILE, JSON.stringify(DEFAULT_CONFIG, null, 2));
        console.log('Created default configuration file');
    }
}

// Read configuration
function readConfig() {
    try {
        const data = fs.readFileSync(DATA_FILE, 'utf8');
        return JSON.parse(data);
    } catch (err) {
        console.error('Error reading config:', err);
        return DEFAULT_CONFIG;
    }
}

// Write configuration
function writeConfig(config) {
    try {
        fs.writeFileSync(DATA_FILE, JSON.stringify(config, null, 2));
        return true;
    } catch (err) {
        console.error('Error writing config:', err);
        return false;
    }
}

// Serve static files
function serveStatic(res, filePath, contentType) {
    fs.readFile(filePath, (err, data) => {
        if (err) {
            res.writeHead(404);
            res.end('Not Found');
            return;
        }
        res.writeHead(200, { 'Content-Type': contentType });
        res.end(data);
    });
}

// Check basic authentication
function checkAuth(req) {
    const authHeader = req.headers.authorization;
    
    if (!authHeader || !authHeader.startsWith('Basic ')) {
        return false;
    }
    
    const base64Credentials = authHeader.slice(6);
    const credentials = Buffer.from(base64Credentials, 'base64').toString('utf8');
    const [username, password] = credentials.split(':');
    
    return username === AUTH_USERNAME && password === AUTH_PASSWORD;
}

// Send 401 Unauthorized response
function sendUnauthorized(res) {
    res.writeHead(401, {
        'WWW-Authenticate': 'Basic realm="Flow Meter Config"',
        'Content-Type': 'text/html; charset=utf-8'
    });
    res.end('<html><body><h1>401 - غير مصرح</h1><p>يرجى إدخال اسم المستخدم وكلمة المرور</p></body></html>');
}

// Create HTTP server
const server = http.createServer((req, res) => {
    const url = new URL(req.url, `http://${req.headers.host}`);
    
    // CORS headers
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
    
    if (req.method === 'OPTIONS') {
        res.writeHead(204);
        res.end();
        return;
    }
    
    // rates.json endpoint - NO authentication (for bash script access)
    if (url.pathname === '/rates.json') {
        const config = readConfig();
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(config));
        return;
    }
    
    // All other endpoints require authentication
    if (!checkAuth(req)) {
        sendUnauthorized(res);
        return;
    }
    
    // API endpoints
    if (url.pathname === '/api/config') {
        if (req.method === 'GET') {
            const config = readConfig();
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify(config));
        } else if (req.method === 'POST') {
            let body = '';
            req.on('data', chunk => body += chunk);
            req.on('end', () => {
                try {
                    const config = JSON.parse(body);
                    
                    // Validate flow meters (must be exactly 3)
                    if (!config.flow_meters || !Array.isArray(config.flow_meters) || config.flow_meters.length !== 3) {
                        throw new Error('Invalid configuration: flow_meters must be an array of exactly 3 meters');
                    }
                    
                    // Validate each meter
                    config.flow_meters.forEach((meter, index) => {
                        if (typeof meter.target_liters !== 'number' || 
                            meter.target_liters < 0 || 
                            meter.target_liters > 200) {
                            throw new Error(`Invalid target_liters for meter ${index + 1}: must be between 0 and 200`);
                        }
                    });
                    
                    // Update timestamp
                    config.last_updated = new Date().toISOString();
                    
                    if (writeConfig(config)) {
                        res.writeHead(200, { 'Content-Type': 'application/json' });
                        res.end(JSON.stringify({ success: true, config }));
                    } else {
                        throw new Error('Failed to write configuration');
                    }
                } catch (err) {
                    res.writeHead(400, { 'Content-Type': 'application/json' });
                    res.end(JSON.stringify({ error: err.message }));
                }
            });
        }
        return;
    }
    
    // Serve static files
    if (url.pathname === '/' || url.pathname === '/index.html') {
        serveStatic(res, path.join(__dirname, 'public', 'index.html'), 'text/html; charset=utf-8');
        return;
    }
    
    // 404 for everything else
    res.writeHead(404);
    res.end('Not Found');
});

// Initialize and start server
initConfig();
server.listen(PORT, '0.0.0.0', () => {
    console.log(`Flow Meter Config Server running on http://0.0.0.0:${PORT}`);
    console.log(`Configuration file: ${DATA_FILE}`);
    console.log(`Authentication enabled - Username: ${AUTH_USERNAME}`);
});
