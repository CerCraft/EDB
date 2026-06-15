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

echo "🚀 Запуск установки Discord Бота (v5.1 - Network Fix)..."

# ==============================================================================
# 1. ПРОВЕРКА И УСТАНОВКА ЗАВИСИМОСТЕЙ
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

# ==============================================================================
# 1.5. ПОЛНАЯ ОЧИСТКА СТАРОЙ ВЕРСИИ
# ==============================================================================
echo "🧹 Очистка старых файлов..."
rm -rf core modules web data
rm -f package.json package-lock.json docker-compose.yml Dockerfile index.js database.js .gitignore
echo "✅ Очистка завершена."

# ==============================================================================
# 2. СОЗДАНИЕ СТРУКТУРЫ И ГЕНЕРАЦИЯ ФАЙЛОВ
# ==============================================================================
mkdir -p core modules/economy modules/shop web/views data/uploads

cat << 'EOF' > package.json
{
  "name": "discord-bot-v5",
  "version": "5.1.0",
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
      - NODE_OPTIONS=--dns-result-order=ipv4first
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
    CREATE TABLE IF NOT EXISTS economy_config (key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE IF NOT EXISTS users (user_id TEXT, guild_id TEXT, balance INTEGER DEFAULT 0, PRIMARY KEY (user_id, guild_id));
    CREATE TABLE IF NOT EXISTS shop_items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, price INTEGER, role_id TEXT, description TEXT, image_url TEXT);
`);

db.prepare("INSERT OR IGNORE INTO economy_config (key, value) VALUES ('currency_name', 'Монеты')").run();
db.prepare("INSERT OR IGNORE INTO economy_config (key, value) VALUES ('currency_icon', '🪙')").run();

export default db;
EOF

cat << 'EOF' > core/botManager.js
import { Client, GatewayIntentBits, Collection, REST, Routes } from 'discord.js';
import path from 'path';
import { fileURLToPath } from 'url';
import db from '../database.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

let bot = null;
let botError = null;

export function getBot() { return bot; }
export function getBotError() { return botError; }

export async function startBot() {
    const settings = getSettings();
    botError = null;
    
    if (!settings.discord_token || !settings.client_id) {
        console.log('⏳ Ожидание настройки токена...');
        return;
    }
    
    if (bot) { 
        console.log('🔄 Перезапуск бота...'); 
        await bot.destroy(); 
        bot = null;
    }
    
    bot = new Client({ 
        intents: [
            GatewayIntentBits.Guilds,
            GatewayIntentBits.GuildMessages,
            GatewayIntentBits.MessageContent,
            GatewayIntentBits.GuildMembers
        ],
        rest: {
            timeout: 30000,
            retries: 3
        },
        ws: {
            large_threshold: 250
        }
    });
    bot.commands = new Collection();
    
    // Загрузка модулей
    const modules = ['economy', 'shop'];
    const commandsToRegister = [];
    for (const mod of modules) {
        try {
            const modulePath = path.join(__dirname, '../modules', mod, 'index.js');
            const module = await import(`file://${modulePath}`);
            if (module.init) {
                const cmds = module.init(bot, db);
                if (cmds) commandsToRegister.push(...cmds);
                console.log(`✅ Модуль [${mod}] загружен`);
            }
        } catch (err) { 
            console.error(`❌ Ошибка модуля [${mod}]:`, err.message); 
        }
    }

    bot.once('ready', async () => {
        console.log(`✅ Бот подключен: ${bot.user.tag}`);
        if (commandsToRegister.length > 0 && settings.guild_id) {
            const rest = new REST({ version: '10', timeout: 30000 }).setToken(settings.discord_token);
            try {
                await rest.put(Routes.applicationGuildCommands(settings.client_id, settings.guild_id), { body: commandsToRegister });
                console.log(`✅ Зарегистрировано ${commandsToRegister.length} команд`);
            } catch (e) { 
                console.error('❌ Ошибка регистрации команд:', e.message); 
            }
        }
    });

    bot.on('interactionCreate', async i => {
        if (!i.isChatInputCommand()) return;
        const cmd = bot.commands.get(i.commandName);
        if (cmd) { 
            try { await cmd.execute(i, db); } 
            catch (err) { 
                console.error(err);
                if (!i.replied) await i.reply({ content: '❌ Произошла ошибка при выполнении команды.', ephemeral: true }).catch(()=>{}); 
            } 
        }
    });

    bot.on('error', (error) => {
        console.error('❌ Ошибка Discord клиента:', error.message);
    });

    try { 
        console.log('🔌 Подключение к Discord...');
        await bot.login(settings.discord_token); 
        console.log('✅ Успешное подключение к Discord');
    } catch (error) { 
        console.error('❌ Ошибка входа в Discord:', error.message); 
        botError = error.message; 
        bot = null; 
    }
}

export function getSettings() {
    const rows = db.prepare('SELECT key, value FROM settings').all();
    const config = {}; rows.forEach(r => config[r.key] = r.value); return config;
}
export function saveSetting(key, value) { db.prepare('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)').run(key, value); }

export function getEconomyConfig() {
    const rows = db.prepare('SELECT key, value FROM economy_config').all();
    const config = {}; rows.forEach(r => config[r.key] = r.value); return config;
}
export function saveEconomyConfig(key, value) { db.prepare('INSERT OR REPLACE INTO economy_config (key, value) VALUES (?, ?)').run(key, value); }
EOF

cat << 'EOF' > modules/economy/index.js
import { SlashCommandBuilder, EmbedBuilder } from 'discord.js';
import { getEconomyConfig } from '../../core/botManager.js';

export function init(bot, db) {
    const cmds = [];
    const bal = new SlashCommandBuilder().setName('balance').setDescription('Проверить ваш баланс');
    cmds.push(bal); 
    
    bot.commands.set('balance', { 
        data: bal, 
        execute: async (i, db) => {
            const config = getEconomyConfig();
            const u = db.prepare('SELECT balance FROM users WHERE user_id = ? AND guild_id = ?').get(i.user.id, i.guildId) || { balance: 0 };
            
            const embed = new EmbedBuilder()
                .setColor('#5865F2')
                .setTitle('💰 Ваш баланс')
                .setDescription(`У вас **${u.balance}** ${config.currency_name} ${config.currency_icon}`);
                
            await i.reply({ embeds: [embed] });
        }
    });
    return cmds;
}
EOF

cat << 'EOF' > modules/shop/index.js
import { SlashCommandBuilder, EmbedBuilder } from 'discord.js';

export function init(bot, db) {
    const cmds = [];
    
    const shopCmd = new SlashCommandBuilder().setName('shop').setDescription('Посмотреть товары в магазине');
    cmds.push(shopCmd);
    bot.commands.set('shop', { 
        data: shopCmd, 
        execute: async (i, db) => {
            const items = db.prepare('SELECT * FROM shop_items').all();
            if (!items.length) return i.reply('🛒 Магазин пока пуст.');
            
            const desc = items.map(item => {
                let text = `🔹 **${item.name}** — **${item.price}** монет\n`;
                if (item.description) text += `_${item.description}_\n`;
                if (item.role_id) text += `🎭 Выдаёт роль при покупке`;
                return text;
            }).join('\n\n');
            
            await i.reply({ embeds: [new EmbedBuilder().setColor('#5865F2').setTitle('🛒 Магазин').setDescription(desc)] });
        }
    });

    const buyCmd = new SlashCommandBuilder()
        .setName('buy')
        .setDescription('Купить товар')
        .addStringOption(o => o.setName('item').setDescription('Название товара').setRequired(true).setAutocomplete(true));
    cmds.push(buyCmd);
    
    bot.commands.set('buy', { 
        data: buyCmd,
        autocomplete: async (i) => {
            const focused = i.options.getFocused().toLowerCase();
            const items = db.prepare('SELECT name FROM shop_items').all().map(x => x.name);
            const filtered = items.filter(x => x.toLowerCase().includes(focused)).slice(0, 25);
            await i.respond(filtered.map(x => ({ name: x, value: x })));
        },
        execute: async (i, db) => {
            const itemName = i.options.getString('item');
            const item = db.prepare('SELECT * FROM shop_items WHERE LOWER(name) = ?').get(itemName.toLowerCase());
            
            if (!item) return i.reply({ content: '❌ Товар не найден.', ephemeral: true });
            
            const u = db.prepare('SELECT balance FROM users WHERE user_id = ? AND guild_id = ?').get(i.user.id, i.guildId) || { balance: 0 };
            if (u.balance < item.price) return i.reply({ content: `❌ Недостаточно средств. Нужно: ${item.price}, у вас: ${u.balance}`, ephemeral: true });
            
            db.prepare('INSERT INTO users (user_id, guild_id, balance) VALUES (?, ?, ?) ON CONFLICT(user_id, guild_id) DO UPDATE SET balance = balance - ?')
              .run(i.user.id, i.guildId, u.balance - item.price, item.price);
              
            let msg = `✅ Вы успешно купили **${item.name}** за ${item.price} монет!`;
            
            if (item.role_id) {
                try {
                    const member = await i.guild.members.fetch(i.user.id);
                    await member.roles.add(item.role_id);
                    msg += `\n🎭 Роль успешно выдана!`;
                } catch (err) {
                    msg += `\n⚠️ Не удалось выдать роль. Убедитесь, что роль бота находится ВЫШЕ покупаемой роли.`;
                }
            }
            
            await i.reply({ content: msg, ephemeral: true });
        }
    });
    return cmds;
}
EOF

cat << 'EOF' > web/server.js
import express from 'express';
import session from 'express-session';
import path from 'path';
import { fileURLToPath } from 'url';
import db from '../database.js';
import bcrypt from 'bcrypt';
import multer from 'multer';
import { getSettings, saveSetting, startBot, getBot, getBotError, getEconomyConfig, saveEconomyConfig } from '../core/botManager.js';

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
app.use(session({ secret: 'v5-super-secret-key', resave: false, saveUninitialized: true }));

const head = `<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<script src="https://cdn.tailwindcss.com"></script>
<script src="https://unpkg.com/lucide@latest"></script>
<script>tailwind.config = { theme: { extend: { colors: { bg: '#0f0f10', card: '#18181b', border: '#27272a', accent: '#5865F2', accentHover: '#4752C4', text: '#e4e4e7', muted: '#a1a1aa' } } } }</script>
<style>body { font-family: system-ui, -apple-system, sans-serif; } .icon { width: 18px; height: 18px; stroke-width: 2; flex-shrink: 0; } input:focus, select:focus { outline: none; border-color: #5865F2; } .tab-active { border-bottom: 2px solid #5865F2; color: #fff; }</style>`;

const layout = (title, content) => `<!DOCTYPE html><html lang="ru"><head>${head}<title>${title}</title></head><body class="bg-bg text-text min-h-screen flex flex-col">${content}<script>lucide.createIcons();</script></body></html>`;
const auth = (req, res, next) => req.session.auth ? next() : res.redirect('/login');

app.get('/', async (req, res) => {
    const s = getSettings();
    if (!s.admin_hash) {
        return res.send(layout('Настройка', `<div class="flex items-center justify-center flex-1 p-4"><div class="bg-card border border-border rounded-xl p-8 w-full max-w-md shadow-2xl">
            <h2 class="text-xl font-semibold text-white mb-6 flex items-center gap-2"><i data-lucide="zap" class="icon text-accent"></i> Настройка бота</h2>
            <form method="POST" action="/setup" class="space-y-4">
                <input name="token" placeholder="Discord Bot Token" required class="w-full bg-bg border border-border rounded-lg px-3 py-2.5 text-sm text-white">
                <div class="grid grid-cols-2 gap-4"><input name="client_id" placeholder="Client ID" required class="w-full bg-bg border border-border rounded-lg px-3 py-2.5 text-sm text-white"><input name="guild_id" placeholder="Guild ID" required class="w-full bg-bg border border-border rounded-lg px-3 py-2.5 text-sm text-white"></div>
                <div class="grid grid-cols-2 gap-4"><input name="admin_user" placeholder="Логин админа" required class="w-full bg-bg border border-border rounded-lg px-3 py-2.5 text-sm text-white"><input type="password" name="admin_pass" placeholder="Пароль" required class="w-full bg-bg border border-border rounded-lg px-3 py-2.5 text-sm text-white"></div>
                <button type="submit" class="w-full bg-accent hover:bg-accentHover text-white font-medium py-2.5 rounded-lg flex items-center justify-center gap-2"><i data-lucide="rocket" class="icon"></i> Сохранить и запустить</button>
            </form></div></div>`));
    }
    res.redirect('/dashboard');
});

app.post('/setup', async (req, res) => {
    const { token, client_id, guild_id, admin_user, admin_pass } = req.body;
    saveSetting('discord_token', token); saveSetting('client_id', client_id); saveSetting('guild_id', guild_id);
    saveSetting('admin_user', admin_user); saveSetting('admin_hash', await bcrypt.hash(admin_pass, 10));
    req.session.auth = true; 
    await startBot(); 
    res.redirect('/dashboard');
});

app.get('/login', (req, res) => res.send(layout('Вход', `<div class="flex items-center justify-center flex-1"><form method="POST" action="/login" class="bg-card border border-border rounded-xl p-8 w-full max-w-sm"><h2 class="text-xl font-semibold text-white mb-4 text-center">Вход</h2><input name="user" placeholder="Логин" required class="w-full bg-bg border border-border rounded-lg px-3 py-2.5 mb-3 text-white"><input type="password" name="pass" placeholder="Пароль" required class="w-full bg-bg border border-border rounded-lg px-3 py-2.5 mb-4 text-white"><button class="w-full bg-accent hover:bg-accentHover text-white font-medium py-2.5 rounded-lg">Войти</button></form></div>`)));
app.post('/login', async (req, res) => { const s = getSettings(); if (req.body.user === s.admin_user && await bcrypt.compare(req.body.pass, s.admin_hash)) { req.session.auth = true; res.redirect('/dashboard'); } else { res.send(`<script>alert('Ошибка'); window.location='/login';</script>`); } });
app.get('/logout', (req, res) => { req.session.destroy(); res.redirect('/login'); });

app.post('/api/restart', auth, async (req, res) => { await startBot(); res.json({ success: true }); });

app.get('/api/roles', auth, async (req, res) => {
    const bot = getBot(); const settings = getSettings();
    if (!bot || !settings.guild_id) return res.status(500).json({ error: 'Бот оффлайн' });
    const guild = bot.guilds.cache.get(settings.guild_id);
    if (!guild) return res.status(404).json({ error: 'Сервер не найден' });
    const roles = guild.roles.cache.filter(r => r.id !== guild.id).sort((a, b) => b.position - a.position).map(r => ({ id: r.id, name: r.name, color: r.hexColor }));
    res.json(roles);
});

app.get('/api/channels', auth, async (req, res) => {
    const bot = getBot(); const settings = getSettings();
    if (!bot || !settings.guild_id) return res.status(500).json({ error: 'Бот оффлайн' });
    const guild = bot.guilds.cache.get(settings.guild_id);
    const channels = guild.channels.cache.filter(c => c.type === 0 || c.type === 2 || c.type === 4).map(c => ({ id: c.id, name: c.name, type: c.type === 4 ? 'category' : (c.type === 2 ? 'voice' : 'text'), parentId: c.parentId }));
    res.json(channels);
});

app.post('/api/channels', auth, async (req, res) => {
    const bot = getBot(); const guild = bot.guilds.cache.get(getSettings().guild_id);
    try {
        const channel = await guild.channels.create({ name: req.body.name, type: req.body.type === 'voice' ? 2 : (req.body.type === 'category' ? 4 : 0), parent: req.body.parentId || null });
        res.json({ success: true });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

app.delete('/api/channels/:id', auth, async (req, res) => {
    const bot = getBot(); const guild = bot.guilds.cache.get(getSettings().guild_id);
    try { const channel = guild.channels.cache.get(req.params.id); if (channel) { await channel.delete(); res.json({ success: true }); } else res.status(404).json({ error: 'Не найден' }); } 
    catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/economy-config', auth, (req, res) => { res.json(getEconomyConfig()); });
app.post('/api/economy-config', auth, (req, res) => {
    saveEconomyConfig('currency_name', req.body.currency_name);
    saveEconomyConfig('currency_icon', req.body.currency_icon);
    res.json({ success: true });
});

app.get('/api/shop', auth, (req, res) => { res.json(db.prepare('SELECT * FROM shop_items').all()); });
app.post('/api/shop', upload.single('image'), auth, async (req, res) => {
    const imageUrl = req.file ? `/uploads/${req.file.filename}` : null;
    db.prepare('INSERT INTO shop_items (name, price, role_id, description, image_url) VALUES (?, ?, ?, ?, ?)')
      .run(req.body.name, req.body.price, req.body.role_id || null, req.body.description, imageUrl);
    res.json({ success: true });
});
app.delete('/api/shop/:id', auth, (req, res) => { db.prepare('DELETE FROM shop_items WHERE id = ?').run(req.params.id); res.json({ success: true }); });

app.get('/dashboard', auth, (req, res) => {
    const settings = getSettings();
    const bot = getBot();
    const isError = getBotError() !== null;
    const statusHtml = bot ? `<span class="text-green-400 flex items-center gap-2"><span class="w-2 h-2 rounded-full bg-green-500"></span> Онлайн</span>` : 
                       (isError ? `<span class="text-red-400 flex items-center gap-2" title="${getBotError()}"><span class="w-2 h-2 rounded-full bg-red-500"></span> Ошибка</span>` : `<span class="text-yellow-400 flex items-center gap-2"><span class="w-2 h-2 rounded-full bg-yellow-500"></span> Ожидание</span>`);

    res.send(layout('Панель управления', `
        <nav class="bg-card border-b border-border px-6 py-4 flex justify-between items-center sticky top-0 z-10">
            <div class="flex items-center gap-3"><i data-lucide="layout-dashboard" class="icon text-accent"></i><h1 class="text-lg font-semibold text-white">Панель управления</h1></div>
            <div class="flex items-center gap-4">
                ${statusHtml}
                <button onclick="restartBot()" class="bg-zinc-800 hover:bg-zinc-700 text-white text-sm font-medium py-2 px-3 rounded-lg flex items-center gap-2 transition-colors"><i data-lucide="refresh-cw" class="icon"></i> Перезапустить</button>
                <a href="/logout" class="text-muted hover:text-white"><i data-lucide="log-out" class="icon"></i></a>
            </div>
        </nav>
        <main class="flex-1 p-6 max-w-5xl mx-auto w-full">
            <div class="flex gap-6 border-b border-border mb-6">
                <button onclick="showTab('economy')" id="tab-economy" class="pb-3 text-sm font-medium tab-active flex items-center gap-2"><i data-lucide="coins" class="icon"></i> Экономика</button>
                <button onclick="showTab('shop')" id="tab-shop" class="pb-3 text-sm font-medium text-muted hover:text-white flex items-center gap-2"><i data-lucide="shopping-cart" class="icon"></i> Магазин</button>
                <button onclick="showTab('channels')" id="tab-channels" class="pb-3 text-sm font-medium text-muted hover:text-white flex items-center gap-2"><i data-lucide="hash" class="icon"></i> Каналы</button>
            </div>

            <div id="view-economy" class="space-y-4">
                <div class="bg-card border border-border rounded-xl p-6">
                    <h3 class="font-medium text-white mb-4 flex items-center gap-2"><i data-lucide="settings" class="icon"></i> Настройка валюты</h3>
                    <form id="economyForm" class="grid grid-cols-1 md:grid-cols-2 gap-4">
                        <div><label class="block text-xs text-muted mb-1">Название валюты</label><input name="currency_name" id="curr_name" class="w-full bg-bg border border-border rounded-lg px-3 py-2 text-white"></div>
                        <div><label class="block text-xs text-muted mb-1">Иконка валюты (эмодзи или URL)</label><input name="currency_icon" id="curr_icon" class="w-full bg-bg border border-border rounded-lg px-3 py-2 text-white"></div>
                        <div class="md:col-span-2"><button type="submit" class="bg-accent hover:bg-accentHover text-white px-4 py-2 rounded-lg text-sm font-medium flex items-center gap-2 w-max"><i data-lucide="save" class="icon"></i> Сохранить</button></div>
                    </form>
                </div>
            </div>

            <div id="view-shop" class="hidden space-y-4">
                <div class="bg-card border border-border rounded-xl p-6">
                    <h3 class="font-medium text-white mb-4 flex items-center gap-2"><i data-lucide="plus" class="icon"></i> Добавить товар</h3>
                    <form id="shopForm" class="grid grid-cols-1 md:grid-cols-2 gap-4">
                        <input name="name" placeholder="Название товара" required class="bg-bg border border-border rounded-lg px-3 py-2 text-white">
                        <input name="price" type="number" placeholder="Цена" required class="bg-bg border border-border rounded-lg px-3 py-2 text-white">
                        <select name="role_id" id="roleSelect" class="bg-bg border border-border rounded-lg px-3 py-2 text-white md:col-span-2">
                            <option value="">-- Без выдачи роли --</option>
                        </select>
                        <input name="description" placeholder="Описание" class="bg-bg border border-border rounded-lg px-3 py-2 text-white md:col-span-2">
                        <div class="md:col-span-2"><label class="block text-xs text-muted mb-1">Картинка товара (необязательно)</label><input type="file" name="image" accept="image/*" class="w-full text-sm text-muted file:mr-4 file:py-2 file:px-4 file:rounded-lg file:border-0 file:bg-accent file:text-white"></div>
                        <div class="md:col-span-2"><button type="submit" class="bg-accent hover:bg-accentHover text-white px-4 py-2 rounded-lg text-sm font-medium flex items-center gap-2 w-max"><i data-lucide="plus-circle" class="icon"></i> Добавить</button></div>
                    </form>
                </div>
                <div id="shopList" class="space-y-3"></div>
            </div>

            <div id="view-channels" class="hidden space-y-4">
                <div class="bg-card border border-border rounded-xl p-4">
                    <h3 class="font-medium text-white mb-4 flex items-center gap-2"><i data-lucide="plus" class="icon"></i> Создать канал</h3>
                    <form id="channelForm" class="flex gap-3">
                        <input type="text" name="name" placeholder="Название" required class="flex-1 bg-bg border border-border rounded-lg px-3 py-2 text-white">
                        <select name="type" class="bg-bg border border-border rounded-lg px-3 py-2 text-white">
                            <option value="text">Текстовый</option><option value="voice">Голосовой</option><option value="category">Категория</option>
                        </select>
                        <button type="submit" class="bg-accent hover:bg-accentHover text-white px-4 py-2 rounded-lg text-sm font-medium flex items-center gap-2"><i data-lucide="plus-circle" class="icon"></i></button>
                    </form>
                </div>
                <div id="channelList" class="space-y-2"></div>
            </div>
        </main>

        <script>
            function showTab(tab) {
                ['economy', 'shop', 'channels'].forEach(t => {
                    document.getElementById('view-' + t).classList.add('hidden');
                    const btn = document.getElementById('tab-' + t);
                    btn.classList.remove('tab-active', 'text-white');
                    btn.classList.add('text-muted');
                });
                document.getElementById('view-' + tab).classList.remove('hidden');
                const activeBtn = document.getElementById('tab-' + tab);
                activeBtn.classList.add('tab-active', 'text-white');
                activeBtn.classList.remove('text-muted');
                
                if (tab === 'shop') loadShop();
                if (tab === 'channels') loadChannels();
                if (tab === 'economy') loadEconomy();
                lucide.createIcons();
            }

            async function restartBot() {
                const btn = event.currentTarget;
                btn.innerHTML = '<i data-lucide="loader-2" class="icon animate-spin"></i> Перезапуск...';
                lucide.createIcons();
                await fetch('/api/restart', { method: 'POST' });
                setTimeout(() => location.reload(), 1500);
            }

            async function loadEconomy() {
                const res = await fetch('/api/economy-config');
                const data = await res.json();
                document.getElementById('curr_name').value = data.currency_name || '';
                document.getElementById('curr_icon').value = data.currency_icon || '';
            }
            document.getElementById('economyForm').onsubmit = async (e) => {
                e.preventDefault();
                const fd = new FormData(e.target);
                await fetch('/api/economy-config', { method: 'POST', body: new URLSearchParams(fd) });
                alert('Сохранено! Нажмите "Перезапустить" в шапке.');
            };

            async function loadShop() {
                const rolesRes = await fetch('/api/roles');
                const roles = await rolesRes.json();
                const select = document.getElementById('roleSelect');
                select.innerHTML = '<option value="">-- Без выдачи роли --</option>' + roles.map(r => `<option value="${r.id}">${r.name}</option>`).join('');

                const itemsRes = await fetch('/api/shop');
                const items = await itemsRes.json();
                const list = document.getElementById('shopList');
                list.innerHTML = items.map(item => {
                    const roleName = roles.find(r => r.id === item.role_id)?.name || 'Нет';
                    const img = item.image_url ? `<img src="${item.image_url}" class="w-10 h-10 rounded object-cover">` : '<div class="w-10 h-10 rounded bg-zinc-800 flex items-center justify-center"><i data-lucide="package" class="icon text-muted"></i></div>';
                    return `<div class="bg-card border border-border rounded-xl p-4 flex justify-between items-center">
                        <div class="flex items-center gap-4">${img}
                            <div><div class="font-medium text-white">${item.name} <span class="text-xs bg-accent/10 text-accent px-2 py-0.5 rounded-full">${item.price} монет</span></div>
                            <div class="text-xs text-muted mt-1">Роль: ${roleName} | ${item.description || 'Без описания'}</div></div>
                        </div>
                        <button onclick="deleteShopItem('${item.id}')" class="text-red-400 hover:text-red-300 p-2"><i data-lucide="trash-2" class="icon"></i></button>
                    </div>`;
                }).join('') || '<p class="text-muted text-center py-8">Магазин пуст</p>';
                lucide.createIcons();
            }
            document.getElementById('shopForm').onsubmit = async (e) => {
                e.preventDefault();
                await fetch('/api/shop', { method: 'POST', body: new FormData(e.target) });
                e.target.reset(); loadShop();
            };
            async function deleteShopItem(id) {
                if(!confirm('Удалить товар?')) return;
                await fetch('/api/shop/' + id, { method: 'DELETE' });
                loadShop();
            }

            async function loadChannels() {
                const res = await fetch('/api/channels');
                const data = await res.json();
                const list = document.getElementById('channelList');
                if (data.error) { list.innerHTML = '<p class="text-red-400 text-center py-8">' + data.error + '</p>'; return; }
                list.innerHTML = data.map(c => `<div class="bg-bg border border-border rounded-lg p-3 flex justify-between items-center">
                    <div class="flex items-center gap-3"><i data-lucide="${c.type === 'voice' ? 'volume-2' : (c.type === 'category' ? 'folder' : 'hash')}" class="icon text-muted"></i><span class="text-sm text-white">${c.name}</span></div>
                    <button onclick="deleteChannel('${c.id}')" class="text-red-400 hover:text-red-300 p-1"><i data-lucide="trash-2" class="icon"></i></button>
                </div>`).join('');
                lucide.createIcons();
            }
            document.getElementById('channelForm').onsubmit = async (e) => {
                e.preventDefault();
                await fetch('/api/channels', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(Object.fromEntries(new FormData(e.target))) });
                e.target.reset(); loadChannels();
            };
            async function deleteChannel(id) {
                if(!confirm('Удалить канал с сервера?')) return;
                await fetch('/api/channels/' + id, { method: 'DELETE' });
                loadChannels();
            }

            showTab('economy');
        </script>
    `));
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
# 3. ЗАПУСК
# ==============================================================================
echo ""
echo "📦 Сборка и запуск контейнера..."
$COMPOSE_CMD up -d --build

echo ""
echo "⏳ Ожидание запуска..."
sleep 5

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
echo "💡 ИСПРАВЛЕНИЯ В v5.1:"
echo "   • Добавлен импорт 'path' (исправлена ошибка модуля shop)"
echo "   • Принудительное использование IPv4 для Discord"
echo "   • Увеличены таймауты и добавлены retry"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"