#!/usr/bin/env node
const dgram = require('dgram');

const STUN_SERVER = 'livekit.market.implica.ru';
const STUN_PORT = 3478;

// STUN Binding Request
const stunRequest = Buffer.from([
    0x00, 0x01, // Binding Request
    0x00, 0x00, // Message Length
    0x21, 0x12, 0xa4, 0x42, // Magic Cookie
    // Transaction ID (12 bytes)
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00
]);

console.log(`🔍 Тестирование TURN/STUN сервера`);
console.log(`Сервер: ${STUN_SERVER}:${STUN_PORT}\n`);

const client = dgram.createSocket('udp4');

const timeout = setTimeout(() => {
    console.log('❌ Timeout - сервер не отвечает на STUN запрос');
    console.log('\nВозможные причины:');
    console.log('1. UDP порт 3478 заблокирован firewall');
    console.log('2. STUN сервер не запущен');
    console.log('3. Проблема с сетью\n');
    client.close();
    process.exit(1);
}, 5000);

client.on('message', (msg) => {
    clearTimeout(timeout);
    console.log('✅ Получен ответ от STUN сервера!');
    console.log(`Размер ответа: ${msg.length} bytes\n`);

    if (msg.length >= 20) {
        const messageType = msg.readUInt16BE(0);
        if (messageType === 0x0101) {
            console.log('✅ STUN Binding Response - сервер работает!\n');

            // Parse STUN attributes
            let offset = 20; // Skip header
            while (offset < msg.length) {
                const attrType = msg.readUInt16BE(offset);
                const attrLength = msg.readUInt16BE(offset + 2);

                if (attrType === 0x0020) { // XOR-MAPPED-ADDRESS
                    console.log('📍 Обнаружен публичный IP (XOR-MAPPED-ADDRESS)');
                }

                offset += 4 + attrLength + (attrLength % 4 ? 4 - attrLength % 4 : 0);
            }
        }
    }

    console.log('🎯 Вывод: TURN/STUN сервер доступен и работает!\n');
    client.close();
});

client.on('error', (err) => {
    clearTimeout(timeout);
    console.log(`❌ Ошибка: ${err.message}\n`);
    client.close();
    process.exit(1);
});

console.log('Отправка STUN Binding Request...');
client.send(stunRequest, STUN_PORT, STUN_SERVER);
