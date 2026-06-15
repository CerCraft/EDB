#!/bin/bash

# ==============================================================================
# 0. АВТОИСПРАВЛЕНИЕ CRLF
# ==============================================================================
if file "$0" | grep -q CRLF; then
    echo "⚠️ Обнаружены Windows-окончания строк (CRLF). Автоматически исправляю..."
    sed -i 's/\r$//' "$0"
    echo "✅ Исправлено. Перезапускаю скрипт..."
    exec "$0" "$@"
fi

echo "🚀 Запуск установки Продвинутого Discord Бота..."

# ==============================================================================
# 1. АВТОМАТИЧЕСКАЯ УСТАНОВКА ЗАВИСИМОСТЕЙ
# ==============================================================================
echo "🔍 Проверка системных зависимостей..."
install_pkg() { echo "📦 Установка $1..."; sudo apt-get update -qq; sudo apt-get install -y $1; }
if ! command -v curl &> /dev/null; then install_pkg curl; fi
if ! command -v git &> /dev/null; then install_pkg git; fi

if ! command -v docker &> /dev/null; then
    echo "🐳 Docker не найден. Устанавливаю..."
    sudo apt-get update -qq
    sudo apt-get install -y docker.io docker-compose-plugin
    sudo systemctl enable docker
    sudo systemctl start docker
    sudo usermod -aG docker $USER
    echo "✅ Docker установлен."
fi

if docker ps &> /dev/null; then
    COMPOSE_CMD="docker compose"
else
    COMPOSE_CMD="sudo docker compose"
fi

echo "✅ Все зависимости проверены."
mkdir -p core modules/economy modules/work modules/games modules/shop web/views data/uploads

# ==============================================================================
# 2. ГЕНЕРАЦИЯ ФАЙЛОВ ПРОЕКТА
# ==============================================================================
cat << 'EOF' > package.json
{
  "name": "pro-discord-bot",
  "version": "4.0.0",
  "main": "index.js",
  "type": "module",
  "scripts": { "start": "node index.js" },
  "dependencies": {
    "discord.js": "^14.14.1",
    "better-sqlite3": "^9.4.3",
    "express": "^4.18.3",
    "express-session": "^1.18.0",
    "ejs": "^3.1.9",
    "bcrypt": "^5.1.1",
    "multer": "^1.4.5-lts.1"
  }
}
EOF

cat << 'EOF' > docker-compose.yml
services:
  bot:
    build: .
    restart: unless-stopped
    ports:
      - "3000:3000"
    volumes:
      - ./data:/app/data
    environment:
      - NODE_ENV=production
EOF

cat << 'EOF' > Dockerfile
FROM node:20-alpine
WORKDIR /app
RUN apk add --no-cache python3 make g++
COPY package*.json ./
RUN npm install
COPY . .
RUN mkdir -p /app/data/uploads
EXPOSE 3000
CMD ["npm", "start"]
EOF

cat << 'EOF' > index.js
import './database.js';
import './web/server.js';
console.log('🚀 Система инициализирована.');
EOF

cat << 'EOF' > database.js
import Database from 'better-sqlite3';
import path from 'path';
import { fileURLToPath } from 'url';
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const db = new Database(path.join(__dirname, 'data', 'bot.db'));

db.exec(`
    CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE IF NOT EXISTS modules (module_id TEXT PRIMARY KEY, name TEXT, enabled INTEGER DEFAULT 1, default_icon TEXT);
    CREATE TABLE IF NOT EXISTS configs (module_id TEXT PRIMARY KEY, config_json TEXT);
    CREATE TABLE IF NOT EXISTS users (user_id TEXT, guild_id TEXT, balance INTEGER DEFAULT 0, last_work INTEGER DEFAULT 0, last_daily INTEGER DEFAULT 0, PRIMARY KEY (user_id, guild_id));
    CREATE TABLE IF NOT EXISTS shop_items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, price INTEGER, role_id TEXT, description TEXT, image_url TEXT);
`);

const mods = [
    {id:'economy', name:'Экономика', icon: 'coins'}, 
    {id:'work', name:'Работы', icon: 'briefcase'}, 
    {id:'games', name:'Мини-игры', icon: 'gamepad-2'}, 
    {id:'shop', name:'Магазин', icon: 'shopping-cart'}
];
const stmtMod = db.prepare('INSERT OR IGNORE INTO modules (module_id, name, default_icon) VALUES (?, ?, ?)');
mods.forEach(m => stmtMod.run(m.id, m.name, m.icon));

// Инициализация конфигов по умолчанию
const defaultConfigs = {
    economy: { currency_icon: '🪙', daily_amount: 100 },
    games: { coinflip_enabled: true, blackjack_enabled: false, blackjack_bg_url: null }
};
const stmtConf = db.prepare('INSERT OR IGNORE INTO configs (module_id, config_json) VALUES (?, ?)');
for (const [key, val] of Object.entries(defaultConfigs)) {
    stmtConf.run(key, JSON.stringify(val));
}

export default db;
EOF

cat << 'EOF' > core/eventBus.js
export class EventBus {
    constructor() { this.listeners = {}; }
    on(event, callback) { if (!this.listeners[event]) this.listeners[event] = []; this.listeners[event].push(callback); }
    emit(event, data) { if (this.listeners[event]) this.listeners[event].forEach(cb => cb(data)); }
}
export const eventBus = new EventBus();
EOF

cat << 'EOF' > core/botManager.js
import { Client, GatewayIntentBits, Collection, REST, Routes } from 'discord.js';
import db from '../database.js';
import { eventBus } from './eventBus.js';
import { loadModules } from './moduleManager.js';

let bot = null;
export function getBot() { return bot; }

export async function startBot() {
    const settings = getSettings();
    if (!settings.discord_token || !settings.client_id) return console.log('⏳ Ожидание настройки...');
    
    if (bot) { 
        console.log('🔄 Перезапуск бота...'); 
        await bot.destroy(); 
        bot = null;
    }
    
    bot = new Client({ intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildMessages, GatewayIntentBits.MessageContent, GatewayIntentBits.GuildMembers] });
    bot.commands = new Collection();
    
    bot.once('ready', async () => {
        console.log(`✅ Бот подключен: ${bot.user.tag}`);
        const commandsData = await loadModules(bot, eventBus);
        if (commandsData.length > 0 && settings.guild_id) {
            const rest = new REST({ version: '10' }).setToken(settings.discord_token);
            try {
                await rest.put(Routes.applicationGuildCommands(settings.client_id, settings.guild_id), { body: commandsData });
                console.log(`✅ Зарегистрировано ${commandsData.length} команд`);
            } catch (e) { console.error('❌ Ошибка команд:', e); }
        }
    });

    bot.on('interactionCreate', async i => {
        if (!i.isChatInputCommand()) return;
        const cmd = bot.commands.get(i.commandName);
        if (cmd) { try { await cmd.execute(i); } catch (err) { if (!i.replied) await i.reply({ content: '❌ Ошибка', ephemeral: true }).catch(()=>{}); } }
    });

    try { await bot.login(settings.discord_token); } 
    catch (error) { console.error('❌ Ошибка токена:', error.message); bot = null; }
}

export function getSettings() {
    const rows = db.prepare('SELECT key, value FROM settings').all();
    const config = {}; rows.forEach(r => config[r.key] = r.value); return config;
}
export function saveSetting(key, value) { db.prepare('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)').run(key, value); }

export function getModuleConfig(moduleId) {
    const row = db.prepare('SELECT config_json FROM configs WHERE module_id = ?').get(moduleId);
    return row ? JSON.parse(row.config_json) : {};
}
export function saveModuleConfig(moduleId, configObj) {
    db.prepare('INSERT OR REPLACE INTO configs (module_id, config_json) VALUES (?, ?)').run(moduleId, JSON.stringify(configObj));
}
EOF

cat << 'EOF' > core/moduleManager.js
import { readdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import db from '../database.js';
const __dirname = dirname(fileURLToPath(import.meta.url));
const modulesPath = join(__dirname, '../modules');

export async function loadModules(bot, eventBus) {
    if (!bot) return [];
    const enabledModules = db.prepare('SELECT module_id FROM modules WHERE enabled = 1').all();
    const enabledIds = enabledModules.map(m => m.module_id);
    const commandsToRegister = [];
    const moduleDirs = readdirSync(modulesPath, { withFileTypes: true }).filter(d => d.isDirectory()).map(d => d.name);
    
    for (const dir of moduleDirs) {
        if (enabledIds.includes(dir)) {
            try {
                const module = await import(`file://${join(modulesPath, dir, 'index.js')}`);
                if (module.init) { const cmds = module.init(bot, db, eventBus); if (cmds) commandsToRegister.push(...cmds); }
            } catch (err) { console.error(`❌ Ошибка модуля [${dir}]:`, err); }
        }
    }
    return commandsToRegister;
}
EOF

# --- МОДУЛИ (Базовые) ---
cat << 'EOF' > modules/economy/index.js
import { SlashCommandBuilder, EmbedBuilder } from 'discord.js';
import { getModuleConfig } from '../../core/botManager.js';
export function init(bot, db, eventBus) {
    const cmds = [];
    const bal = new SlashCommandBuilder().setName('balance').setDescription('Ваш баланс');
    cmds.push(bal); bot.commands.set('balance', { data: bal, execute: async (i) => {
        const config = getModuleConfig('economy');
        const icon = config.currency_icon || '🪙';
        const u = db.prepare('SELECT balance FROM users WHERE user_id = ? AND guild_id = ?').get(i.user.id, i.guildId) || { balance: 0 };
        await i.reply({ embeds: [new EmbedBuilder().setColor('#5865F2').setTitle('Баланс').setDescription(`У вас **${u.balance}** ${icon}`)] });
    }});
    return cmds;
}
EOF

cat << 'EOF' > modules/games/index.js
import { SlashCommandBuilder } from 'discord.js';
import { getModuleConfig } from '../../core/botManager.js';
export function init(bot, db, eventBus) {
    const cmds = [];
    const config = getModuleConfig('games');
    if (config.coinflip_enabled) {
        const coin = new SlashCommandBuilder().setName('coinflip').setDescription('Орел или решка').addIntegerOption(o => o.setName('bet').setDescription('Ставка').setRequired(true).setMinValue(10));
        cmds.push(coin); bot.commands.set('coinflip', { data: coin, execute: async (i) => {
            const bet = i.options.getInteger('bet');
            const u = db.prepare('SELECT balance FROM users WHERE user_id = ? AND guild_id = ?').get(i.user.id, i.guildId) || { balance: 0 };
            if (u.balance < bet) return i.reply({ content: '❌ Недостаточно монет!', ephemeral: true });
            const win = Math.random() > 0.5;
            const newBal = win ? u.balance + bet : u.balance - bet;
            db.prepare('INSERT INTO users (user_id, guild_id, balance) VALUES (?, ?, ?) ON CONFLICT(user_id, guild_id) DO UPDATE SET balance = ?').run(i.user.id, i.guildId, newBal, newBal);
            await i.reply(win ? `🎉 Орел! +${bet} монет.` : `💀 Решка. -${bet} монет.`);
        }});
    }
    return cmds;
}
EOF

# ==============================================================================
# 3. ВЕБ-ПАНЕЛЬ (С УПРАВЛЕНИЕМ КАНАЛАМИ, КОНФИГАМИ И ПЕРЕЗАПУСКОМ)
# ==============================================================================
cat << 'EOF' > web/server.js
import express from 'express';
import session from 'express-session';
import path from 'path';
import { fileURLToPath } from 'url';
import db from '../database.js';
import bcrypt from 'bcrypt';
import multer from 'multer';
import { getSettings, saveSetting, startBot, getBot, getModuleConfig, saveModuleConfig } from '../core/botManager.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const app = express();

const storage = multer.diskStorage({
    destination: (req, file, cb) => cb(null, path.join(__dirname, '../data/uploads/')),
    filename: (req, file, cb) => cb(null, Date.now() + '-' + file.originalname)
});
const upload = multer({ storage });

app.use(express.urlencoded({ extended: true }));
app.use(express.json());
app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));
app.use('/uploads', express.static(path.join(__dirname, '../data/uploads')));
app.use(session({ secret: 'super-secret-session-key-v4', resave: false, saveUninitialized: true }));

const head = `
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<script src="https://cdn.tailwindcss.com"></script>
<script src="https://unpkg.com/lucide@latest"></script>
<script>
  tailwind.config = { theme: { extend: { colors: { bg: '#0f0f10', card: '#18181b', border: '#27272a', accent: '#5865F2', accentHover: '#4752C4', text: '#e4e4e7', muted: '#a1a1aa' } } } }
</script>
<style>
  body { font-family: system-ui, -apple-system, sans-serif; }
  .icon { width: 18px; height: 18px; stroke-width: 2; flex-shrink: 0; }
  .custom-img { width: 40px; height: 40px; object-fit: cover; border-radius: 8px; }
  input:focus, select:focus, textarea:focus { outline: none; border-color: #5865F2; }
  .tab-active { border-bottom: 2px solid #5865F2; color: #fff; }
</style>`;

const layout = (title, content) => `<!DOCTYPE html><html lang="ru"><head>${head}<title>${title}</title></head><body class="bg-bg text-text min-h-screen flex flex-col">${content}<script>lucide.createIcons();</script></body></html>`;
const auth = (req, res, next) => req.session.auth ? next() : res.redirect('/login');

// --- AUTH & SETUP (Сокращено для экономии места, логика та же) ---
app.get('/', async (req, res) => {
    const s = getSettings();
    if (!s.admin_hash) {
        return res.send(layout('Настройка', `<div class="flex items-center justify-center flex-1 p-4"><div class="bg-card border border-border rounded-xl p-8 w-full max-w-md shadow-2xl">
            <h2 class="text-xl font-semibold text-white mb-6 flex items-center gap-2"><i data-lucide="zap" class="icon text-accent"></i> Настройка бота</h2>
            <form method="POST" action="/setup" class="space-y-4">
                <input name="token" placeholder="Discord Bot Token" required class="w-full bg-bg border border-border rounded-lg px-3 py-2.5 text-sm text-white">
                <div class="grid grid-cols-2 gap-4"><input name="client_id" placeholder="Client ID" required class="w-full bg-bg border border-border rounded-lg px-3 py-2.5 text-sm text-white"><input name="guild_id" placeholder="Guild ID" required class="w-full bg-bg border border-border rounded-lg px-3 py-2.5 text-sm text-white"></div>
                <div class="grid grid-cols-2 gap-4"><input name="admin_user" placeholder="Логин" required class="w-full bg-bg border border-border rounded-lg px-3 py-2.5 text-sm text-white"><input type="password" name="admin_pass" placeholder="Пароль" required class="w-full bg-bg border border-border rounded-lg px-3 py-2.5 text-sm text-white"></div>
                <button type="submit" class="w-full bg-accent hover:bg-accentHover text-white font-medium py-2.5 rounded-lg flex items-center justify-center gap-2"><i data-lucide="rocket" class="icon"></i> Запустить</button>
            </form></div></div>`));
    }
    res.redirect('/dashboard');
});
app.post('/setup', async (req, res) => {
    const { token, client_id, guild_id, admin_user, admin_pass } = req.body;
    saveSetting('discord_token', token); saveSetting('client_id', client_id); saveSetting('guild_id', guild_id);
    saveSetting('admin_user', admin_user); saveSetting('admin_hash', await bcrypt.hash(admin_pass, 10));
    req.session.auth = true; await startBot(); res.redirect('/dashboard');
});
app.get('/login', (req, res) => res.send(layout('Вход', `<div class="flex items-center justify-center flex-1"><form method="POST" action="/login" class="bg-card border border-border rounded-xl p-8 w-full max-w-sm"><h2 class="text-xl font-semibold text-white mb-4 text-center">Вход</h2><input name="user" placeholder="Логин" required class="w-full bg-bg border border-border rounded-lg px-3 py-2.5 mb-3 text-white"><input type="password" name="pass" placeholder="Пароль" required class="w-full bg-bg border border-border rounded-lg px-3 py-2.5 mb-4 text-white"><button class="w-full bg-accent hover:bg-accentHover text-white font-medium py-2.5 rounded-lg">Войти</button></form></div>`)));
app.post('/login', async (req, res) => { const s = getSettings(); if (req.body.user === s.admin_user && await bcrypt.compare(req.body.pass, s.admin_hash)) { req.session.auth = true; res.redirect('/dashboard'); } else { res.send(`<script>alert('Ошибка'); window.location='/login';</script>`); } });
app.get('/logout', (req, res) => { req.session.destroy(); res.redirect('/login'); });

// --- RESTART API ---
app.post('/api/restart', auth, async (req, res) => {
    await startBot();
    res.json({ success: true });
});

// --- CHANNELS API ---
app.get('/api/channels', auth, async (req, res) => {
    const bot = getBot();
    const settings = getSettings();
    if (!bot || !settings.guild_id) return res.status(500).json({ error: 'Бот оффлайн или не настроен' });
    const guild = bot.guilds.cache.get(settings.guild_id);
    if (!guild) return res.status(404).json({ error: 'Сервер не найден' });
    
    const channels = guild.channels.cache
        .filter(c => c.type === 0 || c.type === 2 || c.type === 4) // Text, Voice, Category
        .map(c => ({ id: c.id, name: c.name, type: c.type === 4 ? 'category' : (c.type === 2 ? 'voice' : 'text'), parentId: c.parentId }));
    res.json(channels);
});

app.post('/api/channels', auth, async (req, res) => {
    const bot = getBot();
    const settings = getSettings();
    if (!bot) return res.status(500).json({ error: 'Бот оффлайн' });
    const guild = bot.guilds.cache.get(settings.guild_id);
    try {
        const channel = await guild.channels.create({
            name: req.body.name,
            type: req.body.type === 'voice' ? 2 : (req.body.type === 'category' ? 4 : 0),
            parent: req.body.parentId || null
        });
        res.json({ success: true, id: channel.id });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.delete('/api/channels/:id', auth, async (req, res) => {
    const bot = getBot();
    const guild = bot.guilds.cache.get(getSettings().guild_id);
    try {
        const channel = guild.channels.cache.get(req.params.id);
        if (channel) { await channel.delete(); res.json({ success: true }); }
        else res.status(404).json({ error: 'Не найден' });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

// --- MODULE CONFIG API ---
app.get('/api/module-config/:id', auth, (req, res) => {
    res.json(getModuleConfig(req.params.id));
});
app.post('/api/module-config/:id', upload.single('file'), auth, (req, res) => {
    const moduleId = req.params.id;
    let config = getModuleConfig(moduleId);
    
    // Обновляем текстовые поля из req.body
    for (const key in req.body) {
        if (req.body[key] === 'true') config[key] = true;
        else if (req.body[key] === 'false') config[key] = false;
        else config[key] = req.body[key];
    }
    
    // Обработка загрузки файла (например, фон для блэкджека)
    if (req.file) {
        config[req.body.file_key || 'custom_image'] = `/uploads/${req.file.filename}`;
    }
    
    saveModuleConfig(moduleId, config);
    res.json({ success: true });
});

// --- DASHBOARD UI ---
app.get('/dashboard', auth, (req, res) => {
    const mods = db.prepare('SELECT * FROM modules').all();
    const isOnline = getBot() !== null;
    const defaultIcons = { economy: 'coins', work: 'briefcase', games: 'gamepad-2', shop: 'shopping-cart' };

    res.send(layout('Панель управления', `
        <nav class="bg-card border-b border-border px-6 py-4 flex justify-between items-center sticky top-0 z-10">
            <div class="flex items-center gap-3">
                <i data-lucide="layout-dashboard" class="icon text-accent"></i>
                <h1 class="text-lg font-semibold text-white">Панель управления</h1>
            </div>
            <div class="flex items-center gap-4">
                <div class="flex items-center gap-2 text-sm">
                    <span class="w-2 h-2 rounded-full ${isOnline ? 'bg-green-500' : 'bg-red-500'}"></span>
                    <span class="${isOnline ? 'text-green-400' : 'text-red-400'}">${isOnline ? 'Онлайн' : 'Оффлайн'}</span>
                </div>
                <button onclick="restartBot()" class="bg-zinc-800 hover:bg-zinc-700 text-white text-sm font-medium py-2 px-3 rounded-lg flex items-center gap-2 transition-colors">
                    <i data-lucide="refresh-cw" class="icon"></i> Перезапустить бота
                </button>
                <a href="/logout" class="text-muted hover:text-white transition-colors flex items-center gap-1.5 text-sm"><i data-lucide="log-out" class="icon"></i></a>
            </div>
        </nav>
        
        <main class="flex-1 p-6 max-w-5xl mx-auto w-full">
            <!-- Tabs -->
            <div class="flex gap-6 border-b border-border mb-6">
                <button onclick="showTab('modules')" id="tab-modules" class="pb-3 text-sm font-medium tab-active flex items-center gap-2"><i data-lucide="puzzle" class="icon"></i> Модули</button>
                <button onclick="showTab('channels')" id="tab-channels" class="pb-3 text-sm font-medium text-muted hover:text-white flex items-center gap-2"><i data-lucide="hash" class="icon"></i> Каналы сервера</button>
            </div>

            <!-- Modules Tab -->
            <div id="view-modules" class="space-y-4">
                ${mods.map(m => {
                    const defIcon = defaultIcons[m.module_id] || 'box';
                    return `<div class="bg-card border border-border rounded-xl p-4 flex justify-between items-center">
                        <div class="flex items-center gap-4">
                            <div class="w-10 h-10 rounded-lg bg-bg border border-border flex items-center justify-center text-accent">
                                <i data-lucide="${defIcon}" class="icon"></i>
                            </div>
                            <div>
                                <h3 class="font-medium text-white">${m.name}</h3>
                                <p class="text-xs text-muted">${m.enabled ? 'Активен' : 'Отключен'}</p>
                            </div>
                        </div>
                        <div class="flex items-center gap-3">
                            <button onclick="openConfig('${m.module_id}', '${m.name}')" class="text-muted hover:text-white p-2 rounded-lg hover:bg-zinc-800 transition-colors" title="Настроить">
                                <i data-lucide="settings" class="icon"></i>
                            </button>
                            <form method="POST" action="/toggle">
                                <input type="hidden" name="id" value="${m.module_id}">
                                <input type="hidden" name="enabled" value="${m.enabled ? 0 : 1}">
                                <button type="submit" class="px-4 py-2 rounded-lg text-sm font-medium transition-colors flex items-center gap-2 ${m.enabled ? 'bg-red-500/10 text-red-400 hover:bg-red-500/20' : 'bg-green-500/10 text-green-400 hover:bg-green-500/20'}">
                                    <i data-lucide="${m.enabled ? 'toggle-right' : 'toggle-left'}" class="icon"></i>
                                    ${m.enabled ? 'Выключить' : 'Включить'}
                                </button>
                            </form.>
                        </div>
                    </div>`;
                }).join('')}
            </div>

            <!-- Channels Tab -->
            <div id="view-channels" class="hidden space-y-4">
                <div class="bg-card border border-border rounded-xl p-4">
                    <h3 class="font-medium text-white mb-4 flex items-center gap-2"><i data-lucide="plus" class="icon"></i> Создать канал</h3>
                    <form id="createChannelForm" class="flex gap-3">
                        <input type="text" name="name" placeholder="Название канала" required class="flex-1 bg-bg border border-border rounded-lg px-3 py-2 text-sm text-white">
                        <select name="type" class="bg-bg border border-border rounded-lg px-3 py-2 text-sm text-white">
                            <option value="text">Текстовый</option>
                            <option value="voice">Голосовой</option>
                            <option value="category">Категория</option>
                        </select>
                        <button type="submit" class="bg-accent hover:bg-accentHover text-white px-4 py-2 rounded-lg text-sm font-medium flex items-center gap-2">
                            <i data-lucide="plus-circle" class="icon"></i> Создать
                        </button>
                    </form>
                </div>
                <div id="channelsList" class="space-y-2">
                    <p class="text-muted text-center py-8">Загрузка каналов...</p>
                </div>
            </div>
        </main>

        <!-- Config Modal -->
        <div id="configModal" class="fixed inset-0 bg-black/70 hidden items-center justify-center z-50 p-4">
            <div class="bg-card border border-border rounded-xl p-6 w-full max-w-lg">
                <h3 id="configTitle" class="text-lg font-semibold text-white mb-4">Настройка</h3>
                <form id="configForm" class="space-y-4">
                    <div id="configFields"></div>
                    <div class="flex justify-end gap-3 pt-4">
                        <button type="button" onclick="closeConfig()" class="px-4 py-2 text-muted hover:text-white text-sm">Отмена</button>
                        <button type="submit" class="bg-accent hover:bg-accentHover text-white px-4 py-2 rounded-lg text-sm font-medium">Сохранить</button>
                    </div>
                </form>
            </div>
        </div>

        <script>
            function showTab(tab) {
                document.getElementById('view-modules').classList.add('hidden');
                document.getElementById('view-channels').classList.add('hidden');
                document.getElementById('tab-modules').classList.remove('tab-active', 'text-white');
                document.getElementById('tab-modules').classList.add('text-muted');
                document.getElementById('tab-channels').classList.remove('tab-active', 'text-white');
                document.getElementById('tab-channels').classList.add('text-muted');
                
                document.getElementById('view-' + tab).classList.remove('hidden');
                document.getElementById('tab-' + tab).classList.add('tab-active', 'text-white');
                document.getElementById('tab-' + tab).classList.remove('text-muted');
                
                if (tab === 'channels') loadChannels();
                lucide.createIcons();
            }

            async function restartBot() {
                const btn = event.currentTarget;
                btn.innerHTML = '<i data-lucide="loader-2" class="icon animate-spin"></i> Перезапуск...';
                lucide.createIcons();
                await fetch('/api/restart', { method: 'POST' });
                setTimeout(() => location.reload(), 1500);
            }

            async function loadChannels() {
                const res = await fetch('/api/channels');
                const data = await res.json();
                const list = document.getElementById('channelsList');
                if (data.error) { list.innerHTML = '<p class="text-red-400 text-center py-8">' + data.error + '</p>'; return; }
                
                list.innerHTML = data.map(c => `
                    <div class="bg-bg border border-border rounded-lg p-3 flex justify-between items-center">
                        <div class="flex items-center gap-3">
                            <i data-lucide="${c.type === 'voice' ? 'volume-2' : (c.type === 'category' ? 'folder' : 'hash')}" class="icon text-muted"></i>
                            <span class="text-sm text-white">${c.name}</span>
                        </div>
                        <button onclick="deleteChannel('${c.id}')" class="text-red-400 hover:text-red-300 p-1"><i data-lucide="trash-2" class="icon"></i></button>
                    </div>
                `).join('');
                lucide.createIcons();
            }

            async function deleteChannel(id) {
                if(!confirm('Удалить этот канал с Discord сервера?')) return;
                await fetch('/api/channels/' + id, { method: 'DELETE' });
                loadChannels();
            }

            document.getElementById('createChannelForm').onsubmit = async (e) => {
                e.preventDefault();
                const formData = new FormData(e.target);
                await fetch('/api/channels', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(Object.fromEntries(formData))
                });
                e.target.reset();
                loadChannels();
            };

            let currentModule = '';
            async function openConfig(moduleId, moduleName) {
                currentModule = moduleId;
                document.getElementById('configTitle').innerText = 'Настройка: ' + moduleName;
                document.getElementById('configModal').classList.remove('hidden');
                document.getElementById('configModal').classList.add('flex');
                
                const res = await fetch('/api/module-config/' + moduleId);
                const config = await res.json();
                const fields = document.getElementById('configFields');
                fields.innerHTML = '';

                if (moduleId === 'economy') {
                    fields.innerHTML = \`
                        <div><label class="block text-xs text-muted mb-1">Иконка валюты (эмодзи или текст)</label>
                        <input name="currency_icon" value="\${config.currency_icon || '🪙'}" class="w-full bg-bg border border-border rounded-lg px-3 py-2 text-white"></div>
                        <div><label class="block text-xs text-muted mb-1">Сумма ежедневной награды</label>
                        <input type="number" name="daily_amount" value="\${config.daily_amount || 100}" class="w-full bg-bg border border-border rounded-lg px-3 py-2 text-white"></div>
                    \`;
                } else if (moduleId === 'games') {
                    fields.innerHTML = \`
                        <div class="flex items-center gap-3"><input type="checkbox" name="coinflip_enabled" \${config.coinflip_enabled ? 'checked' : ''} class="rounded bg-bg border-border text-accent"> <span class="text-sm text-white">Включить игру "Орел и Решка"</span></div>
                        <div class="flex items-center gap-3"><input type="checkbox" name="blackjack_enabled" \${config.blackjack_enabled ? 'checked' : ''} class="rounded bg-bg border-border text-accent"> <span class="text-sm text-white">Включить игру "Блэкджек" (скоро)</span></div>
                        <div><label class="block text-xs text-muted mb-1">Фон для Блэкджека (картинка)</label>
                        <input type="file" name="file" data-key="blackjack_bg_url" accept="image/*" class="w-full text-sm text-muted file:mr-4 file:py-2 file:px-4 file:rounded-lg file:border-0 file:bg-accent file:text-white"></div>
                    \`;
                } else {
                    fields.innerHTML = '<p class="text-muted text-sm">Дополнительные настройки для этого модуля скоро появятся.</p>';
                }
            }

            function closeConfig() {
                document.getElementById('configModal').classList.add('hidden');
                document.getElementById('configModal').classList.remove('flex');
            }

            document.getElementById('configForm').onsubmit = async (e) => {
                e.preventDefault();
                const formData = new FormData(e.target);
                await fetch('/api/module-config/' + currentModule, { method: 'POST', body: formData });
                closeConfig();
                alert('Настройки сохранены! Не забудьте нажать "Перезапустить бота" в шапке, если изменили команды.');
            };
            lucide.createIcons();
        </script>
    `));
});

app.post('/toggle', auth, async (req, res) => {
    db.prepare('UPDATE modules SET enabled = ? WHERE module_id = ?').run(req.body.enabled, req.body.id);
    await startBot(); res.redirect('/dashboard');
});

const PORT = 3000;
app.listen(PORT, '0.0.0.0', async () => {
    console.log(`🌐 Веб-панель запущена: http://0.0.0.0:${PORT}`);
    await startBot();
});
EOF

cat << 'EOF' > .gitignore
node_modules/
data/
.env
EOF

# ==============================================================================
# 4. ЗАПУСК
# ==============================================================================
echo ""
echo "📦 Сборка и запуск контейнера..."
$COMPOSE_CMD up -d --build

echo ""
echo "⏳ Ожидание запуска..."
sleep 4

PUBLIC_IP=$(curl -4 -s --max-time 3 https://api.ipify.org 2>/dev/null)
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "🌐 Откройте веб-панель:"
[ -n "$PUBLIC_IP" ] && echo "   👉 http://${PUBLIC_IP}:3000"
[ -n "$LOCAL_IP" ] && echo "   👉 http://${LOCAL_IP}:3000"
echo "   👉 http://localhost:3000"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"