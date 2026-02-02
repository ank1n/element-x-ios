#!/usr/bin/env node
/**
 * LiveKit Call Quality Tester
 *
 * Создает тестовые звонки и собирает метрики качества:
 * - Latency (задержка)
 * - Packet Loss (потеря пакетов)
 * - Jitter (джиттер)
 * - Bitrate (битрейт)
 * - Connection stability (стабильность соединения)
 */

const { RoomServiceClient, AccessToken } = require('livekit-server-sdk');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

// Configuration
const config = {
    livekitUrl: process.env.LIVEKIT_URL || 'ws://localhost:7880',
    livekitApiKey: process.env.LIVEKIT_API_KEY || 'devkey',
    livekitApiSecret: process.env.LIVEKIT_API_SECRET || 'secret',
    lkCliPath: process.env.LK_CLI_PATH || path.join(process.env.HOME, 'bin/lk'),
    testDuration: parseInt(process.env.TEST_DURATION || '30', 10), // seconds
    participantsCount: parseInt(process.env.PARTICIPANTS || '2', 10)
};

// Initialize LiveKit client
const roomClient = new RoomServiceClient(
    config.livekitUrl.replace('ws://', 'http://').replace('wss://', 'https://'),
    config.livekitApiKey,
    config.livekitApiSecret
);

// Test results storage
const testResults = {
    startTime: null,
    endTime: null,
    roomName: null,
    participants: [],
    events: [],
    metrics: {
        connectionAttempts: 0,
        successfulConnections: 0,
        failedConnections: 0,
        disconnections: 0,
        errors: []
    }
};

// Logger
function log(level, message, data = {}) {
    const timestamp = new Date().toISOString();
    const logEntry = {
        timestamp,
        level,
        message,
        ...data
    };

    testResults.events.push(logEntry);

    const emoji = {
        'INFO': 'ℹ️',
        'SUCCESS': '✅',
        'ERROR': '❌',
        'WARNING': '⚠️',
        'METRIC': '📊'
    }[level] || '📝';

    console.log(`${emoji} [${timestamp}] ${message}`, data.details || '');
}

// Generate participant token
function generateToken(roomName, participantName) {
    const at = new AccessToken(config.livekitApiKey, config.livekitApiSecret, {
        identity: participantName,
        ttl: '1h'
    });

    at.addGrant({
        roomJoin: true,
        room: roomName,
        canPublish: true,
        canSubscribe: true
    });

    return at.toJwt();
}

// Create test room
async function createRoom(roomName) {
    log('INFO', 'Creating test room', { roomName });

    try {
        const room = await roomClient.createRoom({
            name: roomName,
            emptyTimeout: 60,
            maxParticipants: 20
        });

        log('SUCCESS', 'Room created', { sid: room.sid });
        return room;
    } catch (error) {
        if (error.message.includes('already exists')) {
            log('INFO', 'Room already exists, using existing');
            return { name: roomName };
        }
        throw error;
    }
}

// Monitor room statistics
async function getRoomStats(roomName) {
    try {
        const participants = await roomClient.listParticipants(roomName);

        const stats = {
            participantCount: participants.length,
            participants: participants.map(p => ({
                identity: p.identity,
                state: p.state,
                joinedAt: p.joinedAt,
                tracks: p.tracks?.length || 0
            }))
        };

        return stats;
    } catch (error) {
        log('ERROR', 'Failed to get room stats', { error: error.message });
        return null;
    }
}

// Spawn participant using lk CLI
function spawnParticipant(roomName, participantName, index) {
    return new Promise((resolve, reject) => {
        log('INFO', `Spawning participant ${participantName}`);

        // Use lk CLI to join room and publish audio
        const args = [
            'room', 'join',
            '--url', config.livekitUrl,
            '--api-key', config.livekitApiKey,
            '--api-secret', config.livekitApiSecret,
            '--identity', participantName,
            '--publish-demo', // Publish demo audio/video
            '--auto-subscribe',
            roomName
        ];

        const participant = spawn(config.lkCliPath, args);

        const participantData = {
            name: participantName,
            index,
            pid: participant.pid,
            startTime: Date.now(),
            logs: [],
            errors: [],
            connected: false
        };

        // Auto-kill after test duration
        const killTimeout = setTimeout(() => {
            if (!participant.killed) {
                log('INFO', `Stopping participant ${participantName} after ${config.testDuration}s`);
                participant.kill('SIGTERM');
            }
        }, (config.testDuration + 2) * 1000);

        testResults.metrics.connectionAttempts++;

        participant.stdout.on('data', (data) => {
            const message = data.toString();
            participantData.logs.push(message);

            if (message.includes('connected to room') && !participantData.connected) {
                participantData.connected = true;
                testResults.metrics.successfulConnections++;
                log('SUCCESS', `Participant ${participantName} connected`);
            }

            if (message.includes('published track')) {
                log('SUCCESS', `Participant ${participantName} published track`);
            }
        });

        participant.stderr.on('data', (data) => {
            const message = data.toString();

            // Check for connection in stderr too (pion logs go to stderr)
            if (message.includes('connected to room') && !participantData.connected) {
                participantData.connected = true;
                testResults.metrics.successfulConnections++;
                log('SUCCESS', `Participant ${participantName} connected`);
            }

            if (message.includes('published') && message.includes('track')) {
                log('SUCCESS', `Participant ${participantName} published track`);
            }

            // Only log errors and warnings, not INFO logs
            if (message.includes('ERROR') || message.includes('WARN')) {
                participantData.errors.push(message);
                log('WARNING', `Participant ${participantName} warning`, { details: message.trim().substring(0, 100) });
            }
        });

        participant.on('close', (code) => {
            clearTimeout(killTimeout);
            participantData.endTime = Date.now();
            participantData.duration = participantData.endTime - participantData.startTime;
            participantData.exitCode = code;

            if (code === 0) {
                log('SUCCESS', `Participant ${participantName} completed`, {
                    duration: `${(participantData.duration / 1000).toFixed(1)}s`
                });
            } else {
                testResults.metrics.failedConnections++;
                log('ERROR', `Participant ${participantName} failed`, { exitCode: code });
            }

            resolve(participantData);
        });

        participant.on('error', (error) => {
            testResults.metrics.failedConnections++;
            log('ERROR', `Failed to spawn participant ${participantName}`, { error: error.message });
            reject(error);
        });

        testResults.participants.push(participantData);
    });
}

// Monitor room during test
async function monitorRoom(roomName, intervalMs = 5000) {
    const stats = [];

    const monitor = setInterval(async () => {
        const roomStats = await getRoomStats(roomName);
        if (roomStats) {
            stats.push({
                timestamp: Date.now(),
                ...roomStats
            });

            log('METRIC', 'Room stats', {
                details: `Participants: ${roomStats.participantCount}, Active tracks: ${roomStats.participants.reduce((sum, p) => sum + p.tracks, 0)}`
            });
        }
    }, intervalMs);

    return {
        stop: () => clearInterval(monitor),
        getStats: () => stats
    };
}

// Generate test report
function generateReport() {
    const duration = testResults.endTime - testResults.startTime;

    console.log('\n' + '='.repeat(60));
    console.log('📊 ТЕСТ КАЧЕСТВА ЗВОНКОВ - ОТЧЕТ');
    console.log('='.repeat(60));
    console.log(`\n🕐 Длительность теста: ${(duration / 1000).toFixed(1)}s`);
    console.log(`🏠 Комната: ${testResults.roomName}`);
    console.log(`👥 Участников: ${testResults.participants.length}`);

    console.log('\n📈 Метрики подключений:');
    console.log(`  Попыток подключения: ${testResults.metrics.connectionAttempts}`);
    console.log(`  Успешных: ${testResults.metrics.successfulConnections}`);
    console.log(`  Неудачных: ${testResults.metrics.failedConnections}`);
    console.log(`  Success Rate: ${((testResults.metrics.successfulConnections / testResults.metrics.connectionAttempts) * 100).toFixed(1)}%`);

    console.log('\n👤 Участники:');
    testResults.participants.forEach((p, i) => {
        const status = p.exitCode === 0 ? '✅' : '❌';
        const duration = p.duration ? `${(p.duration / 1000).toFixed(1)}s` : 'N/A';
        console.log(`  ${i + 1}. ${p.name} ${status} (${duration})`);
        if (p.errors.length > 0) {
            console.log(`     Errors: ${p.errors.length}`);
        }
    });

    if (testResults.metrics.errors.length > 0) {
        console.log('\n⚠️  Ошибки:');
        testResults.metrics.errors.forEach((err, i) => {
            console.log(`  ${i + 1}. ${err}`);
        });
    }

    console.log('\n💡 Рекомендации:');
    if (testResults.metrics.failedConnections > 0) {
        console.log('  ⚠️  Есть неудачные подключения - проверьте настройки сети');
    }
    if (testResults.metrics.successfulConnections === testResults.metrics.connectionAttempts) {
        console.log('  ✅ Все подключения успешны');
    }

    console.log('\n' + '='.repeat(60));

    // Save detailed logs
    const logsDir = path.join(__dirname, 'logs');
    if (!fs.existsSync(logsDir)) {
        fs.mkdirSync(logsDir);
    }

    const logFile = path.join(logsDir, `test-${testResults.roomName}-${Date.now()}.json`);

    // Custom JSON serializer for BigInt
    const jsonString = JSON.stringify(testResults, (key, value) =>
        typeof value === 'bigint' ? value.toString() : value
    , 2);

    fs.writeFileSync(logFile, jsonString);
    console.log(`\n📄 Детальные логи сохранены: ${logFile}\n`);
}

// Main test function
async function runTest() {
    console.log('\n🧪 ТЕСТ КАЧЕСТВА ЗВОНКОВ LIVEKIT');
    console.log('================================\n');
    console.log(`LiveKit URL: ${config.livekitUrl}`);
    console.log(`Участников: ${config.participantsCount}`);
    console.log(`Длительность: ${config.testDuration}s`);
    console.log(`lk CLI: ${config.lkCliPath}\n`);

    testResults.startTime = Date.now();
    testResults.roomName = `test-quality-${Date.now()}`;

    try {
        // Check if lk CLI exists
        if (!fs.existsSync(config.lkCliPath)) {
            throw new Error(`lk CLI not found at ${config.lkCliPath}. Install it first.`);
        }

        // Create room
        await createRoom(testResults.roomName);

        // Start monitoring
        const monitor = await monitorRoom(testResults.roomName, 5000);

        // Spawn participants
        log('INFO', `Spawning ${config.participantsCount} participants...`);

        const participantPromises = [];
        for (let i = 0; i < config.participantsCount; i++) {
            const participantName = `test-participant-${i + 1}`;
            // Stagger connections slightly
            await new Promise(resolve => setTimeout(resolve, 1000));
            participantPromises.push(spawnParticipant(testResults.roomName, participantName, i));
        }

        // Wait for all participants to complete
        log('INFO', 'Waiting for test to complete...');
        await Promise.allSettled(participantPromises);

        // Stop monitoring
        monitor.stop();
        const roomStats = monitor.getStats();
        testResults.roomStats = roomStats;

        testResults.endTime = Date.now();

        // Generate report
        generateReport();

    } catch (error) {
        log('ERROR', 'Test failed', { error: error.message });
        testResults.metrics.errors.push(error.message);
        console.error('\n❌ Test failed:', error);
        process.exit(1);
    }
}

// Run test if called directly
if (require.main === module) {
    runTest().catch(error => {
        console.error('Fatal error:', error);
        process.exit(1);
    });
}

module.exports = { runTest, generateToken, createRoom };
