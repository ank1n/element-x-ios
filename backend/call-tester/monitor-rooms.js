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

async function checkRooms() {
    try {
        console.log('\n🔍 ПРОВЕРКА ПОСЛЕДНИХ ЗВОНКОВ\n');

        const rooms = await roomClient.listRooms();
        console.log(`Всего комнат: ${rooms.length}\n`);

        for (const room of rooms) {
            const createdAt = new Date(Number(room.creationTime) * 1000);
            console.log(`📞 Комната: ${room.name}`);
            console.log(`   SID: ${room.sid}`);
            console.log(`   Создана: ${createdAt.toLocaleString('ru-RU')}`);
            console.log(`   Участников сейчас: ${room.numParticipants}`);

            if (room.numParticipants > 0 || true) {
                try {
                    const participants = await roomClient.listParticipants(room.name);
                    console.log(`   История участников: ${participants.length}`);

                    for (const p of participants) {
                        const joinedAt = new Date(Number(p.joinedAt) * 1000);
                        console.log(`\n   👤 ${p.identity}`);
                        console.log(`      State: ${p.state}`);
                        console.log(`      Joined: ${joinedAt.toLocaleString('ru-RU')}`);
                        console.log(`      Tracks: ${p.tracks?.length || 0}`);

                        if (p.tracks && p.tracks.length > 0) {
                            p.tracks.forEach(track => {
                                console.log(`         📹 ${track.type} - ${track.source} - ${track.mimeType || 'unknown'}`);
                                console.log(`            Muted: ${track.muted}, Width: ${track.width || 'N/A'}, Height: ${track.height || 'N/A'}`);
                            });
                        }
                    }
                } catch (e) {
                    console.log(`   ⚠️  Не удалось получить участников: ${e.message}`);
                }
            }
            console.log('');
        }

    } catch (error) {
        console.error('❌ Ошибка:', error.message);
    }
}

checkRooms();
