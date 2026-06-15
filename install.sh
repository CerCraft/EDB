#!/bin/bash

# ==============================================================================
# 0. АВТОИСПРАВЛЕНИЕ CRLF (Windows line endings)
# ==============================================================================
if file "$0" | grep -q CRLF; then
    echo "⚠️ Обнаружены Windows-окончания строк (CRLF). Автоматически исправляю..."
    sed -i 's/\r$//' "$0"
    echo "✅ Исправлено. Перезапускаю скрипт..."
    exec "$0" "$@"
fi

echo "🚀 Запуск установки Модульного Discord Бота..."

# ==============================================================================
# 1. АВТОМАТИЧЕСКАЯ ПРОВЕРКА И УСТАНОВКА ЗАВИСИМОСТЕЙ
# ==============================================================================
echo "🔍 Проверка системных зависимостей..."

# Функция для установки пакетов
install_pkg() {
    echo "📦 Установка $1..."
    sudo apt-get update -qq
    sudo apt-get install -y $1
}

if ! command -v curl &> /dev/null; then install_pkg curl; fi
if ! command -v git &> /dev/null; then install_pkg git; fi

if ! command -v docker &> /dev/null; then
    echo "🐳 Docker не найден. Устанавливаю..."
    sudo apt-get update -qq
    sudo apt-get install -y docker.io docker-compose-plugin
    sudo systemctl enable docker
    sudo systemctl start docker
    # Добавляем текущего пользователя в группу docker, чтобы не нужен был sudo в будущем
    sudo usermod -aG docker $USER
    echo "✅ Docker установлен и настроен."
    echo "⚠️ Примечание: Для применения прав группы может потребоваться переподключение к серверу."
fi

# Проверяем, может ли текущий пользователь использовать docker без sudo
if ! docker ps &> /dev/null; then
    DOCKER_CMD="sudo docker"
    COMPOSE_CMD="sudo docker compose"
else
    DOCKER_CMD="docker"
    COMPOSE_CMD="docker compose"
fi

echo "✅ Все зависимости проверены."

# ==============================================================================
# 2. СОЗДАНИЕ СТРУКТУРЫ ПАПОК
# ==============================================================================
echo "📁 Создание структуры папок..."
mkdir -p core modules/economy modules/work modules/games modules/shop web/views data/uploads

# ==============================================================================
# 3. ГЕНЕРАЦИЯ ФАЙЛОВ ПРОЕКТА
# ==============================================================================
cat << 'EOF' > package.json
{
  "name": "pro-discord-bot",
  "version": "3.2.0",
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
    CREATE TABLE IF NOT EXISTS modules (module_id TEXT PRIMARY KEY, name TEXT, enabled INTEGER DEFAULT 1, icon_url TEXT);
    CREATE TABLE IF NOT EXISTS users (user_id TEXT, guild_id TEXT, balance INTEGER DEFAULT 0, last_work INTEGER DEFAULT 0, last_daily INTEGER DEFAULT 0, PRIMARY KEY (user_id, guild_id));
    CREATE TABLE IF NOT EXISTS shop_items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, price INTEGER, role_id TEXT, description TEXT, image_url TEXT);
`);

// Обновляем схему, если колонки не существуют (для совместимости)
try { db.exec("ALTER TABLE modules ADD COLUMN icon_url TEXT"); } catch(e) {}
try { db.exec("ALTER TABLE shop_items ADD COLUMN image_url TEXT"); } catch(e) {}

const mods = [
    {id:'economy', name:'Экономика', icon: 'coins'}, 
    {id:'work', name:'Работы', icon: 'briefcase'}, 
    {id:'games', name:'Мини-игры', icon: 'dice-5'}, 
    {id:'shop', name:'Магазин', icon: 'shopping-cart'}
];
const stmtMod = db.prepare('INSERT OR IGNORE INTO modules (module_id, name, icon_url) VALUES (?, ?, ?)');
mods.forEach(m => stmtMod.run(m.id, m.name, m.icon));

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
    if (!settings.discord_token || !settings.client_id) return console.log('⏳ Ожидание настройки через веб-панель...');
    if (bot) { console.log('🔄 Перезапуск бота...'); await bot.destroy(); }
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

# --- МОДУЛИ (Краткие версии) ---
cat << 'EOF' > modules/economy/index.js
import { SlashCommandBuilder, EmbedBuilder } from 'discord.js';
export function init(bot, db, eventBus) {
    const cmds = [];
    const bal = new SlashCommandBuilder().setName('balance').setDescription('Ваш баланс');
    cmds.push(bal); bot.commands.set('balance', { data: bal, execute: async (i) => {
        const u = db.prepare('SELECT balance FROM users WHERE user_id = ? AND guild_id = ?').get(i.user.id, i.guildId) || { balance: 0 };
        await i.reply({ embeds: [new EmbedBuilder().setColor('#5865F2').setTitle('Баланс').setDescription(`У вас **${u.balance}** монет.`)] });
    }});
    return cmds;
}
EOF

cat << 'EOF' > modules/work/index.js
import { SlashCommandBuilder } from 'discord.js';
export function init(bot, db, eventBus) {
    const cmds = [];
    const work = new SlashCommandBuilder().setName('work').setDescription('Поработать');
    cmds.push(work); bot.commands.set('work', { data: work, execute: async (i) => {
        const now = Date.now(); let u = db.prepare('SELECT * FROM users WHERE user_id = ? AND guild_id = ?').get(i.user.id, i.guildId) || {};
        if (u.last_work && (now - u.last_work < 3600000)) return i.reply({ content: '⏳ Отдыхайте.', ephemeral: true });
        if (!u.user_id) db.prepare('INSERT INTO users (user_id, guild_id) VALUES (?, ?)').run(i.user.id, i.guildId);
        const reward = Math.floor(Math.random() * 50) + 50;
        db.prepare('INSERT INTO users (user_id, guild_id, balance, last_work) VALUES (?, ?, ?, ?) ON CONFLICT(user_id, guild_id) DO UPDATE SET balance = balance + ?, last_work = ?').run(i.user.id, i.guildId, reward, now, reward, now);
        await i.reply({ content: `⚒️ Вы заработали **${reward}** монет!`, ephemeral: true });
    }});
    return cmds;
}
EOF

cat << 'EOF' > modules/games/index.js
import { SlashCommandBuilder } from 'discord.js';
export function init(bot, db, eventBus) {
    const cmds = [];
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
    return cmds;
}
EOF

cat << 'EOF' > modules/shop/index.js
import { SlashCommandBuilder, EmbedBuilder } from 'discord.js';
export function init(bot, db, eventBus) {
    const cmds = [];
    const shop = new SlashCommandBuilder().setName('shop').setDescription('Список товаров');
    cmds.push(shop); bot.commands.set('shop', { data: shop, execute: async (i) => {
        const items = db.prepare('SELECT * FROM shop_items').all();
        if (!items.length) return i.reply('Магазин пуст.');
        const desc = items.map(item => `🔹 **${item.name}** — ${item.price} монет\n*${item.description}*`).join('\n\n');
        await i.reply({ embeds: [new EmbedBuilder().setColor('#5865F2').setTitle('Магазин').setDescription(desc)] });
    }});
    const buy = new SlashCommandBuilder().setName('buy').setDescription('Купить').addStringOption(o => o.setName('item').setDescription('Название').setRequired(true));
    cmds.push(buy); bot.commands.set('buy', { data: buy, execute: async (i) => {
        const itemName = i.options.getString('item');
        const item = db.prepare('SELECT * FROM shop_items WHERE LOWER(name) LIKE ?').get(`%${itemName.toLowerCase()}%`);
        if (!item) return i.reply({ content: '❌ Товар не найден.', ephemeral: true });
        const u = db.prepare('SELECT balance FROM users WHERE user_id = ? AND guild_id = ?').get(i.user.id, i.guildId) || { balance: 0 };
        if (u.balance < item.price) return i.reply({ content: `❌ Нужно ${item.price} монет.`, ephemeral: true });
        db.prepare('UPDATE users SET balance = balance - ? WHERE user_id = ? AND guild_id = ?').run(item.price, i.user.id, i.guildId);
        let msg = `✅ Вы купили **${item.name}**!`;
        if (item.role_id) { try { const member = await i.guild.members.fetch(i.user.id); await member.roles.add(item.role_id); msg += `\n🎭 Роль выдана!`; } catch(e){} }
        await i.reply({ content: msg, ephemeral: true });
    }});
    return cmds;
}
EOF

# ==============================================================================
# 4. ВЕБ-ПАНЕЛЬ (С ПОДДЕРЖКОЙ ЗАГРУЗКИ ИЗОБРАЖЕНИЙ)
# ==============================================================================
cat << 'EOF' > web/server.js
import express from 'express';
import session from 'express-session';
import path from 'path';
import { fileURLToPath } from 'url';
import { fileURLToPath as getFileUrl } from 'url';
import db from '../database.js';
import bcrypt from 'bcrypt';
import multer from 'multer';
import { getSettings, saveSetting, startBot, getBot } from '../core/botManager.js';

const __dirname = path.dirname(getFileUrl(import.meta.url));
const app = express();

// Настройка загрузки файлов
const storage = multer.diskStorage({
    destination: (req, file, cb) => cb(null, path.join(__dirname, '../data/uploads/')),
    filename: (req, file, cb) => cb(null, Date.now() + '-' + file.originalname)
});
const upload = multer({ storage });

app.use(express.urlencoded({ extended: true }));
app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));
app.use('/uploads', express.static(path.join(__dirname, '../data/uploads'))); // Раздаём картинки
app.use(session({ secret: 'super-secret-session-key', resave: false, saveUninitialized: true }));

const head = `
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<script src="https://cdn.tailwindcss.com"></script>
<script src="https://unpkg.com/lucide@latest"></script>
<script>
  tailwind.config = { theme: { extend: { colors: { bg: '#0f0f10', card: '#18181b', border: '#27272a', accent: '#5865F2', accentHover: '#4752C4', text: '#e4e4e7', muted: '#a1a1aa' } } } }
</script>
<style>
  body { font-family: system-ui, -apple-system, sans-serif; }
  .icon { width: 18px; height: 18px; stroke-width: 2; }
  .custom-img { width: 40px; height: 40px; object-fit: cover; border-radius: 8px; }
  input:focus, textarea:focus { outline: none; border-color: #5865F2; ring: 2px; }
</style>`;

const layout = (title, content) => `<!DOCTYPE html><html lang="ru"><head>${head}<title>${title}</title></head><body class="bg-bg text-text min-h-screen flex flex-col">${content}<script>lucide.createIcons();</script></body></html>`;
const auth = (req, res, next) => req.session.auth ? next() : res.redirect('/login');

// --- SETUP ---
app.get('/', async (req, res) => {
    const s = getSettings();
    if (!s.admin_hash) {
        return res.send(layout('Настройка', `
            <div class="flex items-center justify-center flex-1 p-4">
                <div class="bg-card border border-border rounded-xl p-8 w-full max-w-md shadow-2xl">
                    <div class="flex items-center gap-3 mb-6">
                        <i data-lucide="zap" class="icon text-accent"></i>
                        <h2 class="text-xl font-semibold text-white">Первоначальная настройка</h2>
                    </div>
                    <form method="POST" action="/setup" class="space-y-4">
                        <div><label class="block text-xs font-medium text-muted mb-1.5">Discord Bot Token</label><input name="token" required class="w-full bg-bg border border-border rounded-lg px-3 py-2.5 text-sm text-white transition-colors"></div>
                        <div class="grid grid-cols-2 gap-4">
                            <div><label class="block text-xs font-medium text-muted mb-1.5">Client ID</label><input name="client_id" required class="w-full bg-bg border border-border rounded-lg px-3 py-2.5 text-sm text-white transition-colors"></div>
                            <div><label class="block text-xs font-medium text-muted mb-1.5">Guild ID</label><input name="guild_id" required class="w-full bg-bg border border-border rounded-lg px-3 py-2.5 text-sm text-white transition-colors"></div>
                        </div>
                        <div class="grid grid-cols-2 gap-4 pt-2">
                            <div><label class="block text-xs font-medium text-muted mb-1.5">Логин админа</label><input name="admin_user" required class="w-full bg-bg border border-border rounded-lg px-3 py-2.5 text-sm text-white transition-colors"></div>
                            <div><label class="block text-xs font-medium text-muted mb-1.5">Пароль</label><input type="password" name="admin_pass" required class="w-full bg-bg border border-border rounded-lg px-3 py-2.5 text-sm text-white transition-colors"></div>
                        </div>
                        <button type="submit" class="w-full bg-accent hover:bg-accentHover text-white font-medium py-2.5 rounded-lg transition-colors flex items-center justify-center gap-2 mt-6">
                            <i data-lucide="rocket" class="icon"></i> Сохранить и запустить
                        </button>
                    </form>
                </div>
            </div>
        `));
    }
    res.redirect('/dashboard');
});

app.post('/setup', async (req, res) => {
    const { token, client_id, guild_id, admin_user, admin_pass } = req.body;
    saveSetting('discord_token', token); saveSetting('client_id', client_id); saveSetting('guild_id', guild_id);
    saveSetting('admin_user', admin_user); saveSetting('admin_hash', await bcrypt.hash(admin_pass, 10));
    req.session.auth = true; await startBot(); res.redirect('/dashboard');
});

// --- AUTH ---
app.get('/login', (req, res) => {
    res.send(layout('Вход', `
        <div class="flex items-center justify-center flex-1 p-4">
            <form method="POST" action="/login" class="bg-card border border-border rounded-xl p-8 w-full max-w-sm shadow-2xl">
                <div class="flex items-center gap-3 mb-6 justify-center">
                    <i data-lucide="log-in" class="icon text-accent"></i>
                    <h2 class="text-xl font-semibold text-white">Вход в панель</h2>
                </div>
                <div class="space-y-4">
                    <input name="user" placeholder="Логин" required class="w-full bg-bg border border-border rounded-lg px-3 py-2.5 text-sm text-white transition-colors">
                    <input type="password" name="pass" placeholder="Пароль" required class="w-full bg-bg border border-border rounded-lg px-3 py-2.5 text-sm text-white transition-colors">
                    <button class="w-full bg-accent hover:bg-accentHover text-white font-medium py-2.5 rounded-lg transition-colors flex items-center justify-center gap-2">
                        <i data-lucide="arrow-right" class="icon"></i> Войти
                    </button>
                </div>
            </form>
        </div>
    `));
});

app.post('/login', async (req, res) => {
    const s = getSettings();
    const valid = await bcrypt.compare(req.body.pass, s.admin_hash);
    if (req.body.user === s.admin_user && valid) { req.session.auth = true; res.redirect('/dashboard'); }
    else { res.send(`<script>alert('Неверный логин или пароль'); window.location='/login';</script>`); }
});

app.get('/logout', (req, res) => { req.session.destroy(); res.redirect('/login'); });

// --- DASHBOARD ---
app.get('/dashboard', auth, (req, res) => {
    const mods = db.prepare('SELECT * FROM modules').all();
    const isOnline = getBot() !== null;
    const defaultIcons = { economy: 'coins', work: 'briefcase', games: 'dice-5', shop: 'shopping-cart' };

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
                <a href="/logout" class="text-muted hover:text-white transition-colors flex items-center gap-1.5 text-sm">
                    <i data-lucide="log-out" class="icon"></i> Выйти
                </a>
            </div>
        </nav>
        <main class="flex-1 p-6 max-w-5xl mx-auto w-full">
            <h2 class="text-sm font-medium text-muted uppercase tracking-wider mb-4">Модули</h2>
            <div class="grid gap-3">
                ${mods.map(m => {
                    const defIcon = defaultIcons[m.module_id] || 'box';
                    const imgHtml = m.icon_url ? `<img src="/uploads/${m.icon_url.split('/').pop()}" class="custom-img">` : `<i data-lucide="${defIcon}" class="icon"></i>`;
                    return `<div class="bg-card border border-border rounded-xl p-4 flex justify-between items-center group hover:border-zinc-600 transition-colors">
                        <div class="flex items-center gap-4">
                            <div class="w-10 h-10 rounded-lg bg-bg border border-border flex items-center justify-center text-muted group-hover:text-accent transition-colors overflow-hidden">
                                ${imgHtml}
                            </div>
                            <div>
                                <h3 class="font-medium text-white">${m.name}</h3>
                                <p class="text-xs text-muted">${m.enabled ? 'Активен и загружен' : 'Отключен'}</p>
                            </div>
                        </div>
                        <form method="POST" action="/toggle">
                            <input type="hidden" name="id" value="${m.module_id}">
                            <input type="hidden" name="enabled" value="${m.enabled ? 0 : 1}">
                            <button type="submit" class="px-4 py-2 rounded-lg text-sm font-medium transition-colors flex items-center gap-2 ${m.enabled ? 'bg-red-500/10 text-red-400 hover:bg-red-500/20' : 'bg-green-500/10 text-green-400 hover:bg-green-500/20'}">
                                <i data-lucide="${m.enabled ? 'toggle-right' : 'toggle-left'}" class="icon"></i>
                                ${m.enabled ? 'Выключить' : 'Включить'}
                            </button>
                        </form>
                    </div>`;
                }).join('')}
            </div>
            <div class="mt-8 flex justify-center gap-4">
                <a href="/shop" class="bg-accent hover:bg-accentHover text-white font-medium py-3 px-6 rounded-xl transition-colors flex items-center gap-2 shadow-lg shadow-accent/20">
                    <i data-lucide="store" class="icon"></i> Управление магазином
                </a>
            </div>
        </main>
    `));
});

app.post('/toggle', auth, async (req, res) => {
    db.prepare('UPDATE modules SET enabled = ? WHERE module_id = ?').run(req.body.enabled, req.body.id);
    await startBot(); res.redirect('/dashboard');
});

// --- SHOP ---
app.get('/shop', auth, (req, res) => {
    const items = db.prepare('SELECT * FROM shop_items').all();
    res.send(layout('Магазин', `
        <nav class="bg-card border-b border-border px-6 py-4 flex justify-between items-center sticky top-0 z-10">
            <div class="flex items-center gap-3">
                <a href="/dashboard" class="text-muted hover:text-white transition-colors flex items-center gap-1.5 text-sm">
                    <i data-lucide="arrow-left" class="icon"></i> Назад
                </a>
                <span class="text-zinc-700">/</span>
                <h1 class="text-lg font-semibold text-white flex items-center gap-2">
                    <i data-lucide="store" class="icon text-accent"></i> Управление магазином
                </h1>
            </div>
        </nav>
        <main class="flex-1 p-6 max-w-5xl mx-auto w-full">
            <div class="bg-card border border-border rounded-xl p-6 mb-6">
                <h3 class="font-medium text-white mb-4 flex items-center gap-2"><i data-lucide="plus" class="icon"></i> Добавить товар</h3>
                <form method="POST" action="/shop-add" enctype="multipart/form-data" class="grid grid-cols-1 md:grid-cols-2 gap-4">
                    <input name="name" placeholder="Название (напр. VIP)" required class="bg-bg border border-border rounded-lg px-3 py-2.5 text-sm text-white transition-colors">
                    <input name="price" type="number" placeholder="Цена (монеты)" required class="bg-bg border border-border rounded-lg px-3 py-2.5 text-sm text-white transition-colors">
                    <input name="role_id" placeholder="ID Роли (для автовыдачи, необязательно)" class="bg-bg border border-border rounded-lg px-3 py-2.5 text-sm text-white transition-colors md:col-span-2">
                    <input name="description" placeholder="Описание товара" class="bg-bg border border-border rounded-lg px-3 py-2.5 text-sm text-white transition-colors md:col-span-2">
                    <div class="md:col-span-2">
                        <label class="block text-xs font-medium text-muted mb-1.5">Иконка / Картинка товара (необязательно)</label>
                        <input type="file" name="image" accept="image/*" class="w-full bg-bg border border-border rounded-lg px-3 py-2 text-sm text-muted file:mr-4 file:py-2 file:px-4 file:rounded-lg file:border-0 file:text-sm file:font-medium file:bg-accent file:text-white hover:file:bg-accentHover">
                    </div>
                    <button type="submit" class="md:col-span-2 bg-accent hover:bg-accentHover text-white font-medium py-2.5 rounded-lg transition-colors flex items-center justify-center gap-2">
                        <i data-lucide="plus-circle" class="icon"></i> Добавить товар
                    </button>
                </form>
            </div>
            
            <div class="space-y-3">
                ${items.length === 0 ? '<div class="text-center py-12 text-muted bg-card border border-border rounded-xl border-dashed">Магазин пуст</div>' : ''}
                ${items.map(item => {
                    const imgHtml = item.image_url ? `<img src="/uploads/${item.image_url.split('/').pop()}" class="custom-img">` : `<i data-lucide="package" class="icon"></i>`;
                    return `<div class="bg-card border border-border rounded-xl p-4 flex justify-between items-center group hover:border-zinc-600 transition-colors">
                        <div class="flex items-center gap-4">
                            <div class="w-10 h-10 rounded-lg bg-bg border border-border flex items-center justify-center text-accent overflow-hidden">
                                ${imgHtml}
                            </div>
                            <div>
                                <div class="flex items-center gap-2">
                                    <span class="font-medium text-white">${item.name}</span>
                                    <span class="text-xs bg-accent/10 text-accent px-2 py-0.5 rounded-full font-medium">${item.price} монет</span>
                                    ${item.role_id ? `<span class="text-xs bg-zinc-800 text-muted px-2 py-0.5 rounded-full">Role: ${item.role_id}</span>` : ''}
                                </div>
                                <p class="text-xs text-muted mt-1">${item.description || 'Нет описания'}</p>
                            </div>
                        </div>
                        <form method="POST" action="/shop-del">
                            <input type="hidden" name="id" value="${item.id}">
                            <button type="submit" class="bg-red-500/10 text-red-400 hover:bg-red-500/20 px-3 py-2 rounded-lg text-sm font-medium transition-colors flex items-center gap-2">
                                <i data-lucide="trash-2" class="icon"></i> Удалить
                            </button>
                        </form>
                    </div>`;
                }).join('')}
            </div>
        </main>
    `));
});

app.post('/shop-add', upload.single('image'), auth, (req, res) => { 
    const imageUrl = req.file ? req.file.path : null;
    db.prepare('INSERT INTO shop_items (name, price, role_id, description, image_url) VALUES (?, ?, ?, ?, ?)').run(req.body.name, req.body.price, req.body.role_id || null, req.body.description, imageUrl); 
    res.redirect('/shop'); 
});

app.post('/shop-del', auth, (req, res) => { 
    // Можно добавить удаление файла с диска, но для простоты пока только из БД
    db.prepare('DELETE FROM shop_items WHERE id = ?').run(req.body.id); 
    res.redirect('/shop'); 
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
# 5. ЗАПУСК DOCKER И ВЫВОД ИНСТРУКЦИЙ
# ==============================================================================
echo ""
echo "📦 Сборка и запуск контейнера..."
echo ""

$COMPOSE_CMD up -d --build

echo ""
echo "⏳ Ожидание запуска контейнера..."
sleep 4

PUBLIC_IP=$(curl -4 -s --max-time 3 https://api.ipify.org 2>/dev/null)
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "🌐 Откройте веб-панель в браузере:"
echo ""
if [ -n "$PUBLIC_IP" ]; then
    echo "   👉 По публичному IP:  http://${PUBLIC_IP}:3000"
fi
if [ -n "$LOCAL_IP" ]; then
    echo "   👉 По локальному IP:   http://${LOCAL_IP}:3000"
fi
echo "   👉 Если вы на этом ПК:    http://localhost:3000"
echo ""
echo "⚠️  ВАЖНО: Если ссылки выше не открываются, используйте"
echo "   IP-адрес из панели управления вашего хостинга (VPS)."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 Полезные команды:"
echo "   • Логи:        cd EDB && $COMPOSE_CMD logs -f"
echo "   • Остановить:  cd EDB && $COMPOSE_CMD stop"
echo "   • Перезапуск:  cd EDB && $COMPOSE_CMD restart"
echo ""