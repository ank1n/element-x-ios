const { RoomServiceClient } = require('livekit-server-sdk');

const config = {
    livekitUrl: 'https://livekit.market.implica.ru',
    livekitApiKey: 'devkey',
    livekitApiSecret: 'secret123456789012345678901234567890'
};

const roomClient = new RoomServiceClient(
    config.livekitUrl,
    config.livekitApiKey,
    config.livekitApiSecret
);

let lastRoomCount = 0;
let detectedRooms = new Set();

async function monitor() {
    try {
        const rooms = await roomClient.listRooms();
        const now = new Date().toLocaleTimeString('ru-RU');

        if (rooms.length !== lastRoomCount) {
            console.log(`\n[${now}] 📊 Активных комнат: ${rooms.length}`);
            lastRoomCount = rooms.length;
        }

        for (const room of rooms) {
            const isNew = !detectedRooms.has(room.sid);
            detectedRooms.add(room.sid);

            if (isNew) {
                console.log(`\n🆕 НОВАЯ КОМНАТА: ${room.name}`);
                console.log(`   SID: ${room.sid}`);
                console.log(`   Создана: ${new Date(Number(room.creationTime) * 1000).toLocaleTimeString('ru-RU')}`);
            }

            if (room.numParticipants > 0) {
                const participants = await roomClient.listParticipants(room.name);

                for (const p of participants) {
                    const joinedAt = new Date(Number(p.joinedAt) * 1000).toLocaleTimeString('ru-RU');

                    console.log(`\n[${now}] 👤 ${p.identity} в комнате ${room.name}`);
                    console.log(`   State: ${p.state}, Joined: ${joinedAt}`);
                    console.log(`   Tracks: ${p.tracks?.length || 0}`);

                    if (p.tracks && p.tracks.length > 0) {
                        p.tracks.forEach(track => {
                            const status = track.muted ? '🔇 MUTED' : '🔊 ACTIVE';
                            console.log(`      ${status} ${track.type} (${track.source}) - ${track.mimeType || 'unknown'}`);
                            if (track.width && track.height) {
                                console.log(`         Resolution: ${track.width}x${track.height}`);
                            }
                        });
                    }

                    // Показываем метаданные если есть
                    if (p.metadata) {
                        console.log(`   Metadata: ${p.metadata}`);
                    }
                }
            }
        }

    } catch (error) {
        console.error(`[${new Date().toLocaleTimeString('ru-RU')}] ❌ Ошибка: ${error.message}`);
    }
}

console.log('🔴 ЗАПУЩЕН LIVE МОНИТОРИНГ - market.implica.ru');
console.log('='.repeat(60));
console.log('Ожидаю звонки...\n');

setInterval(monitor, 2000);
monitor(); // First run immediately
