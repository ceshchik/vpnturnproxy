#!/usr/bin/env bash
#
# Nginx decoy site + grpc_pass фронт для VLESS/XHTTP — установщик.
#
# Скрипт НЕ устанавливает и не настраивает Xray — только nginx.
# Вы сами поднимаете Xray с любым inbound (VLESS/XHTTP), который слушает
# локальный порт (например 127.0.0.1:10000), указанный в конце скрипта.
#
# Что делает скрипт:
#   1. Ставит nginx, certbot
#   2. Разворачивает статическую "CDN"-заглушку на 80/443
#   3. Получает Let's Encrypt сертификат (webroot-метод)
#   4. Спрашивает у вас секретный path и порт Xray
#   5. Пишет nginx-конфиг: "/" -> заглушка, path -> grpc_pass 127.0.0.1:PORT
#   6. Печатает домен, path и порт, который нужно указать в "listen"
#      вашего Xray-инбаунда (например "127.0.0.1:10000")
#
# Запускать от root на чистом Ubuntu/Debian.

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Проверки и ввод параметров
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "Запускайте от root: sudo bash $0" >&2
  exit 1
fi

read -rp "Домен (уже указывает A/AAAA-записью на этот сервер): " DOMAIN
read -rp "E-mail для Let's Encrypt (для уведомлений об истечении сертификата): " LE_EMAIL
read -rp "Секретный path для XHTTP (например /assets/abc123/, можно без слэшей — добавлю сам): " XPATH_INPUT
read -rp "Локальный порт Xray (например 10000): " XRAY_PORT

if [[ -z "${DOMAIN}" || -z "${LE_EMAIL}" || -z "${XPATH_INPUT}" || -z "${XRAY_PORT}" ]]; then
  echo "Домен, e-mail, path и порт обязательны." >&2
  exit 1
fi

# Проверка что порт - число
if ! [[ "${XRAY_PORT}" =~ ^[0-9]+$ ]] || [[ "${XRAY_PORT}" -lt 1 || "${XRAY_PORT}" -gt 65535 ]]; then
  echo "Порт должен быть числом от 1 до 65535" >&2
  exit 1
fi

# Нормализуем path: гарантируем "/" в начале и в конце
XPATH="${XPATH_INPUT}"
[[ "${XPATH}" != /* ]] && XPATH="/${XPATH}"
[[ "${XPATH}" != */ ]] && XPATH="${XPATH}/"

# Адрес для подключения nginx к Xray
XRAY_BACKEND="127.0.0.1:${XRAY_PORT}"

WEBROOT="/var/www/${DOMAIN}"
NGINX_SITE="/etc/nginx/sites-available/${DOMAIN}.conf"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/${DOMAIN}.conf"

echo
echo "== Параметры =="
echo "Домен:           ${DOMAIN}"
echo "Path:            ${XPATH}"
echo "Xray backend:    ${XRAY_BACKEND}"
echo

# ---------------------------------------------------------------------------
# 1. Пакеты
# ---------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx certbot curl openssl ufw

# ---------------------------------------------------------------------------
# 2. Статическая "CDN"-заглушка
# ---------------------------------------------------------------------------
mkdir -p "${WEBROOT}"
cat > "${WEBROOT}/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="description" content="Stream your favorite movies and TV shows in HD quality">
    <meta name="keywords" content="streaming, movies, tv shows, video, entertainment">
    <title>StreamHub - Watch Movies & TV Shows Online</title>
    <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='0.9em' font-size='90'>🎬</text></svg>">
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
            background: #0f0f0f;
            color: #e5e5e5;
            line-height: 1.6;
        }

        header {
            background: linear-gradient(to bottom, rgba(0,0,0,0.9), rgba(0,0,0,0));
            padding: 20px 50px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            position: fixed;
            top: 0;
            width: 100%;
            z-index: 1000;
            transition: background 0.3s;
        }

        header.scrolled {
            background: #141414;
        }

        .logo {
            font-size: 32px;
            font-weight: bold;
            color: #e50914;
            text-decoration: none;
            letter-spacing: 2px;
        }

        nav {
            display: flex;
            gap: 30px;
        }

        nav a {
            color: #e5e5e5;
            text-decoration: none;
            font-size: 14px;
            transition: color 0.3s;
        }

        nav a:hover {
            color: #b3b3b3;
        }

        .user-actions {
            display: flex;
            gap: 20px;
            align-items: center;
        }

        .search-icon, .profile-icon {
            cursor: pointer;
            font-size: 20px;
        }

        .hero {
            height: 80vh;
            background: linear-gradient(to bottom, rgba(0,0,0,0.3), rgba(15,15,15,1)),
                        url('data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 600"><rect fill="%23222" width="1200" height="600"/><text x="50%25" y="50%25" font-size="48" fill="%23444" text-anchor="middle" dominant-baseline="middle">HD Video Streaming</text></svg>');
            background-size: cover;
            background-position: center;
            display: flex;
            align-items: center;
            padding: 0 50px;
            margin-top: 70px;
        }

        .hero-content {
            max-width: 600px;
        }

        .hero h1 {
            font-size: 48px;
            margin-bottom: 20px;
            line-height: 1.2;
        }

        .hero p {
            font-size: 18px;
            margin-bottom: 30px;
            color: #b3b3b3;
        }

        .btn {
            padding: 12px 30px;
            font-size: 16px;
            border: none;
            border-radius: 4px;
            cursor: pointer;
            transition: all 0.3s;
            text-decoration: none;
            display: inline-block;
        }

        .btn-primary {
            background: #e50914;
            color: white;
        }

        .btn-primary:hover {
            background: #f40612;
        }

        .btn-secondary {
            background: rgba(109, 109, 110, 0.7);
            color: white;
            margin-left: 10px;
        }

        .btn-secondary:hover {
            background: rgba(109, 109, 110, 0.4);
        }

        .section {
            padding: 50px;
        }

        .section-title {
            font-size: 24px;
            margin-bottom: 20px;
            font-weight: 600;
        }

        .content-row {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(250px, 1fr));
            gap: 10px;
            margin-bottom: 50px;
        }

        .content-card {
            background: #1a1a1a;
            border-radius: 8px;
            overflow: hidden;
            cursor: pointer;
            transition: transform 0.3s;
            position: relative;
        }

        .content-card:hover {
            transform: scale(1.05);
        }

        .content-card img {
            width: 100%;
            height: 350px;
            object-fit: cover;
        }

        .content-placeholder {
            width: 100%;
            height: 350px;
            background: linear-gradient(135deg, #1a1a1a 0%, #2a2a2a 50%, #1a1a1a 100%);
            display: flex;
            align-items: center;
            justify-content: center;
            color: #666;
            font-size: 18px;
        }

        .content-info {
            padding: 15px;
        }

        .content-title {
            font-size: 16px;
            margin-bottom: 5px;
        }

        .content-meta {
            font-size: 12px;
            color: #808080;
        }

        .stats {
            background: #1a1a1a;
            padding: 30px 50px;
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 30px;
            text-align: center;
        }

        .stat-item h3 {
            font-size: 36px;
            color: #e50914;
            margin-bottom: 10px;
        }

        .stat-item p {
            color: #b3b3b3;
        }

        footer {
            background: #141414;
            padding: 50px;
            margin-top: 50px;
        }

        .footer-content {
            max-width: 1200px;
            margin: 0 auto;
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 30px;
        }

        .footer-section h4 {
            margin-bottom: 15px;
            font-size: 16px;
        }

        .footer-section a {
            display: block;
            color: #808080;
            text-decoration: none;
            margin-bottom: 10px;
            font-size: 14px;
        }

        .footer-section a:hover {
            color: #e5e5e5;
        }

        .footer-bottom {
            text-align: center;
            margin-top: 30px;
            padding-top: 20px;
            border-top: 1px solid #333;
            color: #808080;
            font-size: 12px;
        }

        /* Loading animation */
        .loading-indicator {
            position: fixed;
            bottom: 20px;
            right: 20px;
            background: rgba(229, 9, 20, 0.9);
            color: white;
            padding: 10px 20px;
            border-radius: 20px;
            font-size: 12px;
            display: none;
            align-items: center;
            gap: 10px;
            z-index: 2000;
        }

        .loading-indicator.active {
            display: flex;
        }

        .spinner {
            width: 12px;
            height: 12px;
            border: 2px solid #ffffff;
            border-top: 2px solid transparent;
            border-radius: 50%;
            animation: spin 1s linear infinite;
        }

        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }

        /* Video player modal */
        .video-modal {
            display: none;
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            background: rgba(0, 0, 0, 0.95);
            z-index: 3000;
            align-items: center;
            justify-content: center;
        }

        .video-modal.active {
            display: flex;
        }

        .video-container {
            max-width: 1200px;
            width: 90%;
            position: relative;
        }

        .close-btn {
            position: absolute;
            top: -40px;
            right: 0;
            background: none;
            border: none;
            color: white;
            font-size: 32px;
            cursor: pointer;
        }

        .video-player {
            width: 100%;
            aspect-ratio: 16/9;
            background: #000;
            border-radius: 8px;
            position: relative;
            overflow: hidden;
        }

        .video-placeholder {
            width: 100%;
            height: 100%;
            display: flex;
            align-items: center;
            justify-content: center;
            flex-direction: column;
            gap: 20px;
        }

        .play-button {
            width: 80px;
            height: 80px;
            border-radius: 50%;
            background: rgba(229, 9, 20, 0.9);
            border: none;
            color: white;
            font-size: 32px;
            cursor: pointer;
            display: flex;
            align-items: center;
            justify-content: center;
        }

        .play-button:hover {
            background: #e50914;
            transform: scale(1.1);
        }

        @media (max-width: 768px) {
            header {
                padding: 15px 20px;
            }

            nav {
                display: none;
            }

            .hero {
                padding: 0 20px;
            }

            .hero h1 {
                font-size: 32px;
            }

            .section {
                padding: 30px 20px;
            }

            .content-row {
                grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
            }
        }
    </style>
</head>
<body>
    <header id="header">
        <a href="#" class="logo">StreamHub</a>
        <nav>
            <a href="#home">Home</a>
            <a href="#movies">Movies</a>
            <a href="#series">TV Shows</a>
            <a href="#trending">Trending</a>
            <a href="#mylist">My List</a>
        </nav>
        <div class="user-actions">
            <span class="search-icon">🔍</span>
            <span class="profile-icon">👤</span>
        </div>
    </header>

    <div class="hero">
        <div class="hero-content">
            <h1>Unlimited movies, TV shows, and more</h1>
            <p>Watch anywhere. Cancel anytime. Stream in HD quality with no ads.</p>
            <button class="btn btn-primary" onclick="playVideo('Featured Content')">▶ Play</button>
            <button class="btn btn-secondary">ℹ More Info</button>
        </div>
    </div>

    <div class="section">
        <h2 class="section-title">Trending Now</h2>
        <div class="content-row" id="trending-row"></div>
    </div>

    <div class="section">
        <h2 class="section-title">Popular on StreamHub</h2>
        <div class="content-row" id="popular-row"></div>
    </div>

    <div class="section">
        <h2 class="section-title">New Releases</h2>
        <div class="content-row" id="new-row"></div>
    </div>

    <div class="stats">
        <div class="stat-item">
            <h3 id="viewers-count">0</h3>
            <p>Active Viewers</p>
        </div>
        <div class="stat-item">
            <h3 id="content-count">0</h3>
            <p>Hours of Content</p>
        </div>
        <div class="stat-item">
            <h3 id="quality-label">4K Ultra HD</h3>
            <p>Streaming Quality</p>
        </div>
        <div class="stat-item">
            <h3 id="bandwidth">0 Mbps</h3>
            <p>Network Speed</p>
        </div>
    </div>

    <footer>
        <div class="footer-content">
            <div class="footer-section">
                <h4>Company</h4>
                <a href="#about">About Us</a>
                <a href="#careers">Careers</a>
                <a href="#press">Press</a>
                <a href="#blog">Blog</a>
            </div>
            <div class="footer-section">
                <h4>Support</h4>
                <a href="#help">Help Center</a>
                <a href="#contact">Contact Us</a>
                <a href="#terms">Terms of Service</a>
                <a href="#privacy">Privacy Policy</a>
            </div>
            <div class="footer-section">
                <h4>Features</h4>
                <a href="#features">Platform Features</a>
                <a href="#devices">Supported Devices</a>
                <a href="#quality">Video Quality</a>
                <a href="#plans">Subscription Plans</a>
            </div>
            <div class="footer-section">
                <h4>Connect</h4>
                <a href="#facebook">Facebook</a>
                <a href="#twitter">Twitter</a>
                <a href="#instagram">Instagram</a>
                <a href="#youtube">YouTube</a>
            </div>
        </div>
        <div class="footer-bottom">
            <p>&copy; 2026 StreamHub. All rights reserved. Streaming service for entertainment.</p>
        </div>
    </footer>

    <div class="loading-indicator" id="loading">
        <div class="spinner"></div>
        <span>Buffering stream...</span>
    </div>

    <div class="video-modal" id="videoModal">
        <div class="video-container">
            <button class="close-btn" onclick="closeVideo()">×</button>
            <div class="video-player">
                <div class="video-placeholder">
                    <button class="play-button">▶</button>
                    <p style="color: #b3b3b3;">Playing in HD Quality</p>
                </div>
            </div>
        </div>
    </div>

    <script>
        // Header scroll effect
        window.addEventListener('scroll', function() {
            const header = document.getElementById('header');
            if (window.scrollY > 50) {
                header.classList.add('scrolled');
            } else {
                header.classList.remove('scrolled');
            }
        });

        // Generate content cards with procedural images
        function generateContent(containerId, count) {
            const container = document.getElementById(containerId);
            const titles = [
                'The Last Journey', 'City Lights', 'Mystery Island', 'Space Adventure',
                'Love Story', 'Action Hero', 'Dark Secrets', 'Comedy Night',
                'Thriller Zone', 'Drama Series', 'Fantasy World', 'Crime Scene'
            ];

            const colorSchemes = [
                ['#1a1a2e', '#16213e', '#0f3460', '#533483'],
                ['#2c003e', '#7209b7', '#b5179e', '#f72585'],
                ['#03045e', '#0077b6', '#00b4d8', '#90e0ef'],
                ['#582f0e', '#7f4f24', '#936639', '#a68a64'],
                ['#0d1b2a', '#1b263b', '#415a77', '#778da9'],
                ['#1f0318', '#4a1942', '#7b2869', '#a53860'],
                ['#14213d', '#fca311', '#e5e5e5', '#ffffff'],
                ['#22223b', '#4a4e69', '#9a8c98', '#c9ada7'],
                ['#004e89', '#1a659e', '#3a7ca5', '#81b7d2'],
                ['#20221f', '#434a42', '#778c69', '#d5e0c5']
            ];

            for (let i = 0; i < count; i++) {
                const card = document.createElement('div');
                card.className = 'content-card';
                card.onclick = () => playVideo(titles[i % titles.length]);

                const year = 2024 - Math.floor(Math.random() * 3);
                const rating = (7 + Math.random() * 2).toFixed(1);
                const colors = colorSchemes[i % colorSchemes.length];

                // Generate unique image for each card
                const imageData = generatePosterImage(titles[i % titles.length], colors, i);

                card.innerHTML = `
                    <img src="${imageData}" alt="${titles[i % titles.length]}" loading="lazy">
                    <div class="content-info">
                        <div class="content-title">${titles[i % titles.length]}</div>
                        <div class="content-meta">${year} • ⭐ ${rating}</div>
                    </div>
                `;
                container.appendChild(card);
            }
        }

        // Generate poster image using SVG
        function generatePosterImage(title, colors, seed) {
            const patterns = [
                generateGeometricPattern(colors, seed),
                generateCirclePattern(colors, seed),
                generateWavePattern(colors, seed),
                generateDiagonalPattern(colors, seed)
            ];

            const patternType = seed % patterns.length;
            const pattern = patterns[patternType];

            // Create title overlay
            const titleWords = title.split(' ');
            const displayTitle = titleWords.map(w => w.toUpperCase()).join(' ');

            const svg = `
                <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 600">
                    <defs>
                        <linearGradient id="grad${seed}" x1="0%" y1="0%" x2="100%" y2="100%">
                            <stop offset="0%" style="stop-color:${colors[0]};stop-opacity:1" />
                            <stop offset="50%" style="stop-color:${colors[1]};stop-opacity:1" />
                            <stop offset="100%" style="stop-color:${colors[2]};stop-opacity:1" />
                        </linearGradient>
                        <linearGradient id="overlay${seed}" x1="0%" y1="0%" x2="0%" y2="100%">
                            <stop offset="0%" style="stop-color:rgb(0,0,0);stop-opacity:0.3" />
                            <stop offset="100%" style="stop-color:rgb(0,0,0);stop-opacity:0.8" />
                        </linearGradient>
                    </defs>

                    <!-- Background gradient -->
                    <rect width="400" height="600" fill="url(#grad${seed})"/>

                    <!-- Pattern -->
                    ${pattern}

                    <!-- Dark overlay for text readability -->
                    <rect width="400" height="600" fill="url(#overlay${seed})"/>

                    <!-- Title text -->
                    <text x="200" y="480" font-family="Arial, sans-serif" font-size="32" font-weight="bold"
                          fill="white" text-anchor="middle" letter-spacing="2">
                        ${titleWords[0].toUpperCase()}
                    </text>
                    ${titleWords[1] ? `<text x="200" y="520" font-family="Arial, sans-serif" font-size="32" font-weight="bold"
                          fill="white" text-anchor="middle" letter-spacing="2">
                        ${titleWords.slice(1).join(' ').toUpperCase()}
                    </text>` : ''}

                    <!-- HD Badge -->
                    <rect x="320" y="20" width="60" height="30" rx="4" fill="rgba(229, 9, 20, 0.9)"/>
                    <text x="350" y="40" font-family="Arial, sans-serif" font-size="16" font-weight="bold"
                          fill="white" text-anchor="middle">HD</text>
                </svg>
            `;

            return 'data:image/svg+xml;base64,' + btoa(unescape(encodeURIComponent(svg)));
        }

        function generateGeometricPattern(colors, seed) {
            let shapes = '';
            const count = 15 + (seed % 10);
            for (let i = 0; i < count; i++) {
                const x = (seed * 37 + i * 53) % 400;
                const y = (seed * 73 + i * 97) % 600;
                const size = 30 + (i * 17) % 70;
                const opacity = 0.1 + (i % 5) * 0.05;
                const color = colors[(i + seed) % colors.length];

                if (i % 3 === 0) {
                    shapes += `<rect x="${x}" y="${y}" width="${size}" height="${size}" fill="${color}" opacity="${opacity}" transform="rotate(${i * 15} ${x + size/2} ${y + size/2})"/>`;
                } else {
                    shapes += `<circle cx="${x}" cy="${y}" r="${size/2}" fill="${color}" opacity="${opacity}"/>`;
                }
            }
            return shapes;
        }

        function generateCirclePattern(colors, seed) {
            let shapes = '';
            const rings = 4 + (seed % 3);
            for (let i = 0; i < rings; i++) {
                const r = 100 + i * 80;
                const opacity = 0.15 - i * 0.03;
                const color = colors[i % colors.length];
                shapes += `<circle cx="200" cy="300" r="${r}" fill="none" stroke="${color}" stroke-width="${20 + i * 5}" opacity="${opacity}"/>`;
            }
            return shapes;
        }

        function generateWavePattern(colors, seed) {
            let shapes = '';
            const waves = 8 + (seed % 5);
            for (let i = 0; i < waves; i++) {
                const y = i * 80 - 100;
                const color = colors[i % colors.length];
                const opacity = 0.2 - (i % 3) * 0.05;
                const amplitude = 30 + (seed % 20);
                shapes += `<path d="M0,${y} Q100,${y - amplitude} 200,${y} T400,${y} L400,${y + 60} Q300,${y + 60 + amplitude} 200,${y + 60} T0,${y + 60} Z" fill="${color}" opacity="${opacity}"/>`;
            }
            return shapes;
        }

        function generateDiagonalPattern(colors, seed) {
            let shapes = '';
            const lines = 12 + (seed % 6);
            for (let i = 0; i < lines; i++) {
                const offset = i * 60 - 200;
                const color = colors[i % colors.length];
                const opacity = 0.15;
                const width = 30 + (i % 4) * 10;
                shapes += `<line x1="${offset}" y1="0" x2="${offset + 600}" y2="600" stroke="${color}" stroke-width="${width}" opacity="${opacity}"/>`;
            }
            return shapes;
        }

        // Initialize content
        generateContent('trending-row', 6);
        generateContent('popular-row', 6);
        generateContent('new-row', 6);

        // Simulate traffic and stats
        function updateStats() {
            const viewers = Math.floor(15000 + Math.random() * 5000);
            const content = Math.floor(48000 + Math.random() * 2000);
            const bandwidth = (45 + Math.random() * 20).toFixed(1);

            document.getElementById('viewers-count').textContent = viewers.toLocaleString();
            document.getElementById('content-count').textContent = content.toLocaleString() + '+';
            document.getElementById('bandwidth').textContent = bandwidth + ' Mbps';
        }

        updateStats();
        setInterval(updateStats, 5000);

        // Simulate periodic "buffering" to mimic streaming traffic
        function simulateTraffic() {
            const loading = document.getElementById('loading');

            if (Math.random() > 0.7) {
                loading.classList.add('active');
                setTimeout(() => {
                    loading.classList.remove('active');
                }, 2000 + Math.random() * 3000);
            }
        }

        setInterval(simulateTraffic, 10000);

        // Video player
        function playVideo(title) {
            const modal = document.getElementById('videoModal');
            modal.classList.add('active');

            // Simulate loading indicator
            const loading = document.getElementById('loading');
            loading.classList.add('active');
            setTimeout(() => {
                loading.classList.remove('active');
            }, 2000);
        }

        function closeVideo() {
            const modal = document.getElementById('videoModal');
            modal.classList.remove('active');
        }

        // Close modal on ESC key
        document.addEventListener('keydown', function(e) {
            if (e.key === 'Escape') {
                closeVideo();
            }
        });

        // Simulate background network activity
        function simulateNetworkActivity() {
            // Generate periodic requests to simulate streaming
            fetch(window.location.href, { method: 'HEAD' })
                .catch(() => {});
        }

        setInterval(simulateNetworkActivity, 8000 + Math.random() * 4000);

        // Generate random "keepalive" events
        setInterval(() => {
            const event = new CustomEvent('stream-keepalive', {
                detail: {
                    timestamp: Date.now(),
                    bandwidth: (45 + Math.random() * 20).toFixed(1),
                    quality: '1080p'
                }
            });
            window.dispatchEvent(event);
        }, 15000);

        // Log realistic streaming metrics
        console.log('%c🎬 StreamHub Initialized', 'color: #e50914; font-size: 16px; font-weight: bold;');
        console.log('%cPlatform: Web Streaming Service', 'color: #b3b3b3;');
        console.log('%cVersion: 2.4.1', 'color: #b3b3b3;');
        console.log('%cCDN: Active', 'color: #46d369;');

        setInterval(() => {
            console.log(`[${new Date().toISOString()}] Stream buffer: ${(Math.random() * 10).toFixed(2)}MB | Quality: 1080p | Bitrate: ${(8000 + Math.random() * 2000).toFixed(0)}kbps`);
        }, 30000);
    </script>
</body>
</html>
HTML

mkdir -p "${WEBROOT}/.well-known/acme-challenge"

# ---------------------------------------------------------------------------
# 3. Временный HTTP-вхост для выпуска сертификата (webroot)
# ---------------------------------------------------------------------------
cat > "${NGINX_SITE}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${WEBROOT};

    location /.well-known/acme-challenge/ {
        allow all;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

ln -sf "${NGINX_SITE}" "${NGINX_SITE_LINK}"
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
nginx -t
systemctl reload nginx || systemctl restart nginx

# ---------------------------------------------------------------------------
# 4. Сертификат Let's Encrypt
# ---------------------------------------------------------------------------
certbot certonly --webroot -w "${WEBROOT}" \
  -d "${DOMAIN}" \
  -m "${LE_EMAIL}" \
  --agree-tos --non-interactive --no-eff-email

CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
if [[ ! -f "${CERT_DIR}/fullchain.pem" ]]; then
  echo "Сертификат не выпущен — проверьте DNS-запись домена и вывод certbot выше." >&2
  exit 1
fi

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'HOOK'
#!/usr/bin/env bash
systemctl reload nginx
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

# ---------------------------------------------------------------------------
# 5. Полный nginx-конфиг: TLS + decoy + grpc_pass на локальный порт Xray
# ---------------------------------------------------------------------------
cat > "${NGINX_SITE}" <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    root ${WEBROOT};
    index index.html;

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    server_tokens off;
    client_header_timeout 5m;
    keepalive_timeout 5m;

    # Секретный путь XHTTP -> локальный порт вашего Xray-инбаунда
    location ${XPATH} {
        proxy_pass http://127.0.0.1:${XRAY_BACKEND};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 315s;
        proxy_send_timeout 5m;
        client_body_timeout 5m;
        client_max_body_size 0;
    }

    # Скрытые/служебные файлы — не отдавать
    location ~ /\. {
        deny all;
    }

    # Всё остальное — обычная заглушка "CDN"
    location / {
        try_files \$uri \$uri/ =404;
    }
}

# HTTP -> редирект на HTTPS (ACME challenge оставляем живым для продления)
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${WEBROOT};

    location /.well-known/acme-challenge/ {
        allow all;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

nginx -t
systemctl restart nginx

# ---------------------------------------------------------------------------
# 6. Firewall
# ---------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  ufw allow 80/tcp  >/dev/null 2>&1 || true
  ufw allow 443/tcp >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# 7. Итог
# ---------------------------------------------------------------------------
echo
echo "======================================================================"
echo " Nginx настроен. Xray нужно поднять отдельно."
echo "======================================================================"
echo "Домен:             ${DOMAIN}"
echo "Path:              ${XPATH}"
echo "Nginx site:        ${NGINX_SITE}"
echo
echo "В inbound вашего Xray укажите:"
echo "  \"listen\": \"${XRAY_BACKEND}\","
echo "  \"protocol\": \"vless\" (или другой),"
echo "  streamSettings.network = \"grpc\","
echo "  streamSettings.grpcSettings.serviceName = \"${XPATH%/}\""
echo
echo "Пример конфига Xray inbound:"
echo "{"
echo "  \"listen\": \"${XRAY_BACKEND}\","
echo "  \"protocol\": \"vless\","
echo "  \"settings\": { ... },"
echo "  \"streamSettings\": {"
echo "    \"network\": \"grpc\","
echo "    \"grpcSettings\": {"
echo "      \"serviceName\": \"${XPATH%/}\""
echo "    }"
echo "  }"
echo "}"
echo "======================================================================"
