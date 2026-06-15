#!/bin/bash

echo "🚀 Запуск установки Модульного Discord Бота..."

# 1. Создаем структуру папок
echo "📁 Создание структуры папок..."
mkdir -p core modules/economy modules/work modules/games modules/shop web/views data

# 2. Создаем файлы проекта (используем 'EOF' чтобы bash не ломал код JS)

cat << 'EOF' > package.json
{
  "name": "pro-discord-bot",
  "version": "3.0.0",
  "main": "index.js",
  "type": "module",
  "scripts": { "start": "node index.js" },
  "dependencies": {
    "discord.js": "^14.14.1",
    "better-sqlite3": "^9.4.3",
    "express": "^4.18.3",
    "express-session": "^1.18.0",
    "ejs": "^3.1.9",
    "bcrypt": "^5.1.1"
  }
}
EOF

cat << 'EOF' > docker-compose.yml
version: '3.8'
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
RUN mkdir -p /app/data
EXPOSE 3000
CMD ["npm", "start"]
EOF

cat << 'EOF' > index.js
import './database.js';
import './web/server.js';
console.log('🚀 Система инициализирована. Откройте http://localhost:3000');
EOF

cat << 'EOF' > database.js
import Database from 'better-sqlite3';
import path from 'path';
import { fileURLToPath } from 'url';
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const db = new Database(path.join(__dirname, 'data', 'bot.db'));
db.exec(\`
    CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);
    CREATE TABLE IF NOT EXISTS modules (module_id TEXT PRIMARY KEY, name TEXT, enabled INTEGER DEFAULT 1);
    CREATE TABLE IF NOT EXISTS users (user_id TEXT, guild_id TEXT, balance INTEGER DEFAULT 0, last_work INTEGER DEFAULT 0, last_daily INTEGER DEFAULT 0, PRIMARY KEY (user_id, guild_id));
    CREATE TABLE IF NOT EXISTS shop_items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, price INTEGER, role_id TEXT, description TEXT);
\`);
const mods = [{id:'economy', name:'💰 Экономика'}, {id:'work', name:'⚒️ Работы'}, {id:'games', name:'🎲 Мини-игры'}, {id:'shop', name:'🛒 Магазин'}];
const stmtMod = db.prepare('INSERT OR IGNORE INTO modules (module_id, name) VALUES (?, ?)');
mods.forEach(m => stmtMod.run(m.id, m.name));
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
    if (bot) { console.log('🔄 Перезапуск бота...'); await bot.destroy(); }
    bot = new Client({ intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildMessages, GatewayIntentBits.MessageContent, GatewayIntentBits.GuildMembers] });
    bot.commands = new Collection();
    bot.once('ready', async () => {
        console.log(\`✅ Бот подключен: \${bot.user.tag}\`);
        const commandsData = await loadModules(bot, eventBus);
        if (commandsData.length > 0 && settings.guild_id) {
            const rest = new REST({ version: '10' }).setToken(settings.discord_token);
            try {
                await rest.put(Routes.applicationGuildCommands(settings.client_id, settings.guild_id), { body: commandsData });
                console.log(\`✅ Зарегистрировано \${commandsData.length} команд\`);
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
                const module = await import(\`file://\${join(modulesPath, dir, 'index.js')}\`);
                if (module.init) { const cmds = module.init(bot, db, eventBus); if (cmds) commandsToRegister.push(...cmds); }
            } catch (err) { console.error(\`❌ Ошибка модуля [\${dir}]:\`, err); }
        }
    }
    return commandsToRegister;
}
EOF

# --- МОДУЛИ (Краткие версии для примера, можно расширить) ---
cat << 'EOF' > modules/economy/index.js
import { SlashCommandBuilder, EmbedBuilder } from 'discord.js';
export function init(bot, db, eventBus) {
    const cmds = [];
    const bal = new SlashCommandBuilder().setName('balance').setDescription('Ваш баланс');
    cmds.push(bal); bot.commands.set('balance', { data: bal, execute: async (i) => {
        const u = db.prepare('SELECT balance FROM users WHERE user_id = ? AND guild_id = ?').get(i.user.id, i.guildId) || { balance: 0 };
        await i.reply({ embeds: [new EmbedBuilder().setColor('#5865F2').setTitle('💰 Баланс').setDescription(\`У вас **\${u.balance}** монет.\`)] });
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
        await i.reply({ content: \`⚒️ Вы заработали **\${reward}** монет!\`, ephemeral: true });
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
        await i.reply(win ? \`🎉 Орел! Вы выиграли **\${bet}** монет.\` : \`💀 Решка. Вы проиграли **\${bet}** монет.\`);
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
        const desc = items.map(item => \`🔹 **\${item.name}** — \${item.price} монет\n*\${item.description}*\`).join('\\n\\n');
        await i.reply({ embeds: [new EmbedBuilder().setColor('#5865F2').setTitle('🛒 Магазин').setDescription(desc)] });
    }});
    const buy = new SlashCommandBuilder().setName('buy').setDescription('Купить').addStringOption(o => o.setName('item').setDescription('Название').setRequired(true));
    cmds.push(buy); bot.commands.set('buy', { data: buy, execute: async (i) => {
        const itemName = i.options.getString('item');
        const item = db.prepare('SELECT * FROM shop_items WHERE LOWER(name) LIKE ?').get(\`%\${itemName.toLowerCase()}%\`);
        if (!item) return i.reply({ content: '❌ Товар не найден.', ephemeral: true });
        const u = db.prepare('SELECT balance FROM users WHERE user_id = ? AND guild_id = ?').get(i.user.id, i.guildId) || { balance: 0 };
        if (u.balance < item.price) return i.reply({ content: \`❌ Нужно \${item.price} монет.\`, ephemeral: true });
        db.prepare('UPDATE users SET balance = balance - ? WHERE user_id = ? AND guild_id = ?').run(item.price, i.user.id, i.guildId);
        let msg = \`✅ Вы купили **\${item.name}**!\`;
        if (item.role_id) { try { const member = await i.guild.members.fetch(i.user.id); await member.roles.add(item.role_id); msg += \`\\n🎭 Роль выдана!\`; } catch(e){} }
        await i.reply({ content: msg, ephemeral: true });
    }});
    return cmds;
}
EOF

# --- ВЕБ-ПАНЕЛЬ (Сокращенная, но полностью рабочая версия с Tailwind) ---
cat << 'EOF' > web/server.js
import express from 'express';
import session from 'express-session';
import path from 'path';
import { fileURLToPath } from 'url';
import db from '../database.js';
import bcrypt from 'bcrypt';
import { getSettings, saveSetting, startBot, getBot } from '../core/botManager.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const app = express();
app.use(express.urlencoded({ extended: true }));
app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));
app.use(session({ secret: 'secret-key', resave: false, saveUninitialized: true }));

const tw = \`<script src="https://cdn.tailwindcss.com"></script><script>tailwind.config={theme:{extend:{colors:{blurple:'#5865F2', dark:'#202225', darker:'#18191c', card:'#2f3136'}}}}</script>\`;
const layout = (t, c) => \`<!DOCTYPE html><html><head><meta charset="UTF-8"><title>\${t}</title>\${tw}</head><body class="bg-dark text-gray-200 font-sans min-h-screen flex flex-col">\${c}</body></html>\`;
const auth = (req, res, next) => req.session.auth ? next() : res.redirect('/login');

app.get('/', async (req, res) => {
    const s = getSettings();
    if (!s.admin_hash) {
        return res.send(layout('Настройка', \`<div class="flex items-center justify-center flex-1 p-4"><div class="bg-card p-8 rounded-lg shadow-xl w-full max-w-md border border-gray-700">
            <h2 class="text-2xl font-bold text-white mb-2">🚀 Настройка бота</h2>
            <form method="POST" action="/setup" class="space-y-4">
                <input name="token" placeholder="Discord Bot Token" required class="w-full bg-darker border border-gray-600 rounded p-2 text-white">
                <input name="client_id" placeholder="Client ID (Application ID)" required class="w-full bg-darker border border-gray-600 rounded p-2 text-white">
                <input name="guild_id" placeholder="Guild ID (ID сервера)" required class="w-full bg-darker border border-gray-600 rounded p-2 text-white">
                <div class="grid grid-cols-2 gap-4">
                    <input name="admin_user" placeholder="Логин админа" required class="w-full bg-darker border border-gray-600 rounded p-2 text-white">
                    <input type="password" name="admin_pass" placeholder="Пароль админа" required class="w-full bg-darker border border-gray-600 rounded p-2 text-white">
                </div>
                <button type="submit" class="w-full bg-blurple hover:bg-indigo-700 text-white font-bold py-2 rounded">Сохранить и Запустить</button>
            </form></div></div>\`));
    }
    res.redirect('/dashboard');
});

app.post('/setup', async (req, res) => {
    const { token, client_id, guild_id, admin_user, admin_pass } = req.body;
    saveSetting('discord_token', token); saveSetting('client_id', client_id); saveSetting('guild_id', guild_id);
    saveSetting('admin_user', admin_user); saveSetting('admin_hash', await bcrypt.hash(admin_pass, 10));
    req.session.auth = true; await startBot(); res.redirect('/dashboard');
});

app.get('/login', (req, res) => {
    res.send(layout('Вход', \`<div class="flex items-center justify-center flex-1"><form method="POST" action="/login" class="bg-card p-8 rounded-lg w-full max-w-sm border border-gray-700">
        <h2 class="text-xl font-bold text-white mb-4 text-center">Вход</h2>
        <input name="user" placeholder="Логин" required class="w-full bg-darker border border-gray-600 rounded p-2 mb-3 text-white">
        <input type="password" name="pass" placeholder="Пароль" required class="w-full bg-darker border border-gray-600 rounded p-2 mb-4 text-white">
        <button class="w-full bg-blurple hover:bg-indigo-700 text-white font-bold py-2 rounded">Войти</button></form></div>\`));
});

app.post('/login', async (req, res) => {
    const s = getSettings();
    if (req.body.user === s.admin_user && await bcrypt.compare(req.body.pass, s.admin_hash)) {
        req.session.auth = true; res.redirect('/dashboard');
    } else { res.send(\`<script>alert('Неверно'); window.location='/login';</script>\`); }
});

app.get('/logout', (req, res) => { req.session.destroy(); res.redirect('/login'); });

app.get('/dashboard', auth, (req, res) => {
    const mods = db.prepare('SELECT * FROM modules').all();
    const status = getBot() ? '<span class="text-green-400">● Онлайн</span>' : '<span class="text-red-400">● Оффлайн</span>';
    res.send(layout('Панель', \`<nav class="bg-card border-b border-gray-700 p-4 flex justify-between items-center"><h1 class="text-xl font-bold text-white">⚙️ Панель</h1><div class="flex items-center gap-4"><span class="text-sm">\${status}</span><a href="/logout" class="text-sm text-gray-400">Выйти</a></div></nav>
        <main class="flex-1 p-8 max-w-4xl mx-auto w-full"><h2 class="text-lg font-semibold mb-4">Модули</h2><div class="grid gap-4">
        \${mods.map(m => \`<div class="bg-card p-4 rounded-lg border border-gray-700 flex justify-between items-center">
            <div><h3 class="font-bold text-white">\${m.name}</h3><p class="text-xs text-gray-400">\${m.enabled ? 'Активен' : 'Отключен'}</p></div>
            <form method="POST" action="/toggle"><input type="hidden" name="id" value="\${m.module_id}"><input type="hidden" name="enabled" value="\${m.enabled ? 0 : 1}">
            <button type="submit" class="px-4 py-2 rounded text-sm font-bold \${m.enabled ? 'bg-red-500/20 text-red-400' : 'bg-green-500/20 text-green-400'}">\${m.enabled ? 'Выключить' : 'Включить'}</button></form></div>\`).join('')}
        </div><div class="mt-8 text-center"><a href="/shop" class="inline-block bg-blurple hover:bg-indigo-700 text-white font-bold py-3 px-6 rounded-lg">🛒 Управление магазином</a></div></main>\`));
});

app.post('/toggle', auth, async (req, res) => {
    db.prepare('UPDATE modules SET enabled = ? WHERE module_id = ?').run(req.body.enabled, req.body.id);
    await startBot(); res.redirect('/dashboard');
});

app.get('/shop', auth, (req, res) => {
    const items = db.prepare('SELECT * FROM shop_items').all();
    res.send(layout('Магазин', \`<nav class="bg-card border-b border-gray-700 p-4 flex justify-between items-center"><h1 class="text-xl font-bold text-white">🛒 Магазин</h1><a href="/dashboard" class="text-sm text-gray-400">← Назад</a></nav>
        <main class="flex-1 p-8 max-w-4xl mx-auto w-full">
        <div class="bg-card p-6 rounded-lg border border-gray-700 mb-6"><h3 class="font-bold text-white mb-4">Добавить товар</h3>
        <form method="POST" action="/shop-add" class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <input name="name" placeholder="Название" required class="bg-darker border border-gray-600 rounded p-2 text-white">
            <input name="price" type="number" placeholder="Цена" required class="bg-darker border border-gray-600 rounded p-2 text-white">
            <input name="role_id" placeholder="ID Роли (необязательно)" class="bg-darker border border-gray-600 rounded p-2 text-white md:col-span-2">
            <input name="description" placeholder="Описание" class="bg-darker border border-gray-600 rounded p-2 text-white md:col-span-2">
            <button type="submit" class="md:col-span-2 bg-blurple hover:bg-indigo-700 text-white font-bold py-2 rounded">Добавить</button>
        </form></div>
        <div class="space-y-3">\${items.map(i => \`<div class="bg-card p-4 rounded-lg border border-gray-700 flex justify-between items-center">
            <div><span class="font-bold text-white">\${i.name}</span> <span class="text-blurple font-bold ml-2">\${i.price} 💰</span><p class="text-xs text-gray-400 mt-1">\${i.description||''}</p></div>
            <form method="POST" action="/shop-del"><input type="hidden" name="id" value="\${i.id}"><button type="submit" class="bg-red-500/20 text-red-400 px-3 py-1 rounded text-sm">Удалить</button></form></div>\`).join('')}</div></main>\`));
});

app.post('/shop-add', auth, (req, res) => { db.prepare('INSERT INTO shop_items (name, price, role_id, description) VALUES (?, ?, ?, ?)').run(req.body.name, req.body.price, req.body.role_id||null, req.body.description); res.redirect('/shop'); });
app.post('/shop-del', auth, (req, res) => { db.prepare('DELETE FROM shop_items WHERE id = ?').run(req.body.id); res.redirect('/shop'); });

app.listen(3000, async () => { console.log('🌐 Веб-панель: http://localhost:3000'); await startBot(); });
EOF

# 3. Запуск установки
echo "📦 Установка зависимостей и запуск через Docker..."
if command -v docker-compose &> /dev/null || command -v docker &> /dev/null && docker compose version &> /dev/null; then
    docker compose up -d --build
    echo "✅ Успешно! Откройте в браузере: http://localhost:3000"
else
    echo "⚠️ Docker не найден. Установите Docker и запустите 'docker-compose up -d --build' вручную."
fi