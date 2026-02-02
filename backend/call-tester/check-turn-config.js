const { RoomServiceClient } = require('livekit-server-sdk');
const axios = require('axios');

async function checkTurnConfig() {
    console.log('🔍 ПРОВЕРКА TURN КОНФИГУРАЦИИ\n');
    
    // Проверяем доступность TURN портов
    const turnPorts = [3478, 5349];
    const server = 'livekit.market.implica.ru';
    
    console.log(`Проверяем TURN порты на ${server}:\n`);
    
    for (const port of turnPorts) {
        try {
            const result = await axios.get(`http://${server}:${port}`, {
                timeout: 3000,
                validateStatus: () => true
            });
            console.log(`✅ Порт ${port}: Доступен (HTTP ${result.status})`);
        } catch (error) {
            if (error.code === 'ECONNREFUSED') {
                console.log(`❌ Порт ${port}: Закрыт или TURN не запущен`);
            } else if (error.code === 'ETIMEDOUT') {
                console.log(`⚠️  Порт ${port}: Timeout - возможно firewall`);
            } else {
                console.log(`⚠️  Порт ${port}: ${error.message}`);
            }
        }
    }
    
    console.log('\n📝 Рекомендации:');
    console.log('1. TURN должен слушать UDP 3478 (STUN/TURN)');
    console.log('2. TURN должен слушать TCP/TLS 5349 (TURNS)');
    console.log('3. Нужен доступ к серверу для настройки\n');
}

checkTurnConfig();
