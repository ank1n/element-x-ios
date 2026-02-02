const { RoomServiceClient, AccessToken } = require('livekit-server-sdk');
const { spawn } = require('child_process');

const config = {
    livekitUrl: 'wss://livekit.market.implica.ru',
    livekitApiKey: 'devkey',
    livekitApiSecret: 'secret123456789012345678901234567890',
    lkCliPath: process.env.HOME + '/bin/lk'
};

const roomClient = new RoomServiceClient(
    config.livekitUrl.replace('wss://', 'https://'),
    config.livekitApiKey,
    config.livekitApiSecret
);

async function measureConnectionTime() {
    const roomName = `benchmark-${Date.now()}`;
    const participantName = 'benchmark-participant';

    console.log(`\n🧪 ТЕСТ СКОРОСТИ ПОДКЛЮЧЕНИЯ`);
    console.log(`Комната: ${roomName}\n`);

    // Create room
    const roomStart = Date.now();
    await roomClient.createRoom({ name: roomName });
    const roomTime = Date.now() - roomStart;
    console.log(`✅ Комната создана за: ${roomTime}ms`);

    // Measure connection time
    return new Promise((resolve) => {
        const startTime = Date.now();
        let connectedTime = null;
        let firstTrackTime = null;

        const args = [
            'room', 'join',
            '--url', config.livekitUrl,
            '--api-key', config.livekitApiKey,
            '--api-secret', config.livekitApiSecret,
            '--identity', participantName,
            '--publish-demo',
            '--auto-subscribe',
            roomName
        ];

        const participant = spawn(config.lkCliPath, args);

        participant.stderr.on('data', (data) => {
            const message = data.toString();

            if (message.includes('connected to room') && !connectedTime) {
                connectedTime = Date.now() - startTime;
                console.log(`✅ Подключение к комнате: ${connectedTime}ms`);
            }

            if (message.includes('published') && message.includes('track') && !firstTrackTime) {
                firstTrackTime = Date.now() - startTime;
                console.log(`✅ Первый трек опубликован: ${firstTrackTime}ms`);
            }
        });

        setTimeout(() => {
            participant.kill();

            const totalTime = Date.now() - startTime;

            resolve({
                roomCreation: roomTime,
                connectionTime: connectedTime || totalTime,
                firstTrackTime: firstTrackTime || totalTime,
                totalTime
            });
        }, 10000);
    });
}

async function runBenchmark(runs = 3) {
    console.log('=' .repeat(60));
    console.log('📊 BENCHMARK: СКОРОСТЬ ПОДКЛЮЧЕНИЯ К LIVEKIT');
    console.log('=' .repeat(60));

    const results = [];

    for (let i = 0; i < runs; i++) {
        console.log(`\nТест ${i + 1}/${runs}:`);
        const result = await measureConnectionTime();
        results.push(result);

        // Wait between tests
        await new Promise(resolve => setTimeout(resolve, 2000));
    }

    // Calculate averages
    const avg = {
        roomCreation: results.reduce((sum, r) => sum + r.roomCreation, 0) / runs,
        connectionTime: results.reduce((sum, r) => sum + r.connectionTime, 0) / runs,
        firstTrackTime: results.reduce((sum, r) => sum + r.firstTrackTime, 0) / runs,
        totalTime: results.reduce((sum, r) => sum + r.totalTime, 0) / runs
    };

    console.log('\n' + '='.repeat(60));
    console.log('📊 РЕЗУЛЬТАТЫ (среднее по ' + runs + ' тестам):');
    console.log('='.repeat(60));
    console.log(`Создание комнаты:        ${avg.roomCreation.toFixed(0)}ms`);
    console.log(`Подключение к комнате:   ${avg.connectionTime.toFixed(0)}ms`);
    console.log(`Публикация первого трека: ${avg.firstTrackTime.toFixed(0)}ms`);
    console.log(`Общее время:             ${avg.totalTime.toFixed(0)}ms`);
    console.log('='.repeat(60));

    return avg;
}

runBenchmark(3);
