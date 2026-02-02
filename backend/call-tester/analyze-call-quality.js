const { RoomServiceClient } = require('livekit-server-sdk');

const livekitHost = 'wss://livekit.market.implica.ru';
const apiKey = 'devkey';
const apiSecret = 'secret123456789012345678901234567890';

const roomService = new RoomServiceClient(livekitHost, apiKey, apiSecret);

async function analyzeCallQuality() {
    console.log('\n🔍 АНАЛИЗ КАЧЕСТВА ЗВОНКОВ\n');
    console.log('Получаю активные комнаты...\n');

    const rooms = await roomService.listRooms();

    if (rooms.length === 0) {
        console.log('❌ Нет активных комнат');
        console.log('\n💡 Сделай звонок и запусти скрипт повторно\n');
        return;
    }

    for (const room of rooms) {
        console.log(`📞 Комната: ${room.name}`);
        console.log(`   Участников: ${room.numParticipants}`);
        console.log(`   Создана: ${new Date(Number(room.creationTime) / 1000000).toLocaleTimeString()}`);

        const participants = await roomService.listParticipants(room.name);

        for (const p of participants) {
            console.log(`\n   👤 ${p.identity}`);
            console.log(`      State: ${p.state} (${getStateName(p.state)})`);
            console.log(`      Joined: ${new Date(Number(p.joinedAt) * 1000).toLocaleTimeString()}`);

            if (p.tracks && p.tracks.length > 0) {
                console.log(`      📊 Tracks:`);

                for (const track of p.tracks) {
                    const type = track.type === 2 ? '🎤 Audio' : '📹 Video';
                    const codec = track.mimeType ? track.mimeType.split('/')[1] : 'unknown';

                    console.log(`         ${type} (${codec})`);

                    if (track.width && track.height) {
                        console.log(`            Resolution: ${track.width}x${track.height}`);
                    }

                    // Ключевые метрики качества
                    if (track.simulcast) {
                        console.log(`            ✅ Simulcast enabled`);
                    }

                    if (track.muted) {
                        console.log(`            🔇 Muted`);
                    }
                }
            }
        }

        console.log('\n' + '─'.repeat(60));
    }

    console.log('\n💡 Рекомендации:');
    console.log('   1. Проверь пропускную способность сети');
    console.log('   2. Убедись, что используется TURN relay для проблемных сетей');
    console.log('   3. Снизь разрешение видео если есть лаги\n');
}

function getStateName(state) {
    switch(state) {
        case 0: return 'JOINING';
        case 1: return 'JOINED';
        case 2: return 'ACTIVE';
        case 3: return 'DISCONNECTED';
        default: return 'UNKNOWN';
    }
}

// Запуск с интервалом
console.log('🚀 Запускаю мониторинг качества звонков...');
console.log('📊 Обновление каждые 5 секунд\n');

analyzeCallQuality();
setInterval(analyzeCallQuality, 5000);
