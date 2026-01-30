const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
const { EgressClient, EncodedFileOutput, S3Upload } = require('livekit-server-sdk');

const app = express();

// Middleware
app.use(helmet());
app.use(cors());
app.use(morgan('combined'));
app.use(express.json());

// Configuration from environment variables
const config = {
    livekitUrl: process.env.LIVEKIT_URL || 'wss://livekit.market.implica.ru',
    livekitApiKey: process.env.LIVEKIT_API_KEY || 'devkey',
    livekitApiSecret: process.env.LIVEKIT_API_SECRET || 'secret123456789012345678901234567890',
    s3Endpoint: process.env.S3_ENDPOINT || 'http://minio.minio.svc.cluster.local:9000',
    s3AccessKey: process.env.S3_ACCESS_KEY || 'minioadmin',
    s3SecretKey: process.env.S3_SECRET_KEY || 'MinioAdmin2026!',
    s3Bucket: process.env.S3_BUCKET || 'livekit-recordings',
    port: parseInt(process.env.PORT, 10) || 3000
};

// Initialize LiveKit Egress Client
const egressClient = new EgressClient(
    config.livekitUrl,
    config.livekitApiKey,
    config.livekitApiSecret
);

// Health check
app.get('/health', (req, res) => {
    res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// Start recording
app.post('/api/recording/start', async (req, res) => {
    const { roomName, layout = 'grid-dark' } = req.body;

    if (!roomName) {
        return res.status(400).json({
            success: false,
            error: 'roomName is required'
        });
    }

    try {
        const timestamp = Date.now();
        const filepath = `recordings/${roomName}_${timestamp}.mp4`;

        const fileOutput = new EncodedFileOutput({
            filepath: filepath,
            output: {
                case: 's3',
                value: new S3Upload({
                    accessKey: config.s3AccessKey,
                    secret: config.s3SecretKey,
                    endpoint: config.s3Endpoint,
                    bucket: config.s3Bucket,
                    forcePathStyle: true
                })
            }
        });

        const info = await egressClient.startRoomCompositeEgress(roomName, {
            file: fileOutput,
            layout: layout
        });

        console.log(`Recording started for room ${roomName}, egressId: ${info.egressId}`);

        res.json({
            success: true,
            egressId: info.egressId,
            status: info.status,
            roomName: roomName,
            filepath: filepath
        });
    } catch (error) {
        console.error('Failed to start recording:', error);
        res.status(500).json({
            success: false,
            error: error.message
        });
    }
});

// Stop recording
app.post('/api/recording/stop', async (req, res) => {
    const { egressId } = req.body;

    if (!egressId) {
        return res.status(400).json({
            success: false,
            error: 'egressId is required'
        });
    }

    try {
        const info = await egressClient.stopEgress(egressId);

        console.log(`Recording stopped, egressId: ${egressId}`);

        res.json({
            success: true,
            egressId: egressId,
            status: info.status
        });
    } catch (error) {
        console.error('Failed to stop recording:', error);
        res.status(500).json({
            success: false,
            error: error.message
        });
    }
});

// Get recording status
app.get('/api/recording/status/:egressId', async (req, res) => {
    const { egressId } = req.params;

    try {
        const list = await egressClient.listEgress({ egressId: egressId });
        const egress = list.find(e => e.egressId === egressId);

        if (!egress) {
            return res.status(404).json({
                success: false,
                error: 'Egress not found'
            });
        }

        res.json({
            success: true,
            egress: {
                egressId: egress.egressId,
                roomName: egress.roomName,
                status: egress.status,
                startedAt: egress.startedAt,
                endedAt: egress.endedAt
            }
        });
    } catch (error) {
        console.error('Failed to get recording status:', error);
        res.status(500).json({
            success: false,
            error: error.message
        });
    }
});

// List all active recordings
app.get('/api/recording/list', async (req, res) => {
    const { roomName } = req.query;

    try {
        const options = roomName ? { roomName } : {};
        const list = await egressClient.listEgress(options);

        res.json({
            success: true,
            recordings: list.map(e => ({
                egressId: e.egressId,
                roomName: e.roomName,
                status: e.status,
                startedAt: e.startedAt,
                endedAt: e.endedAt
            }))
        });
    } catch (error) {
        console.error('Failed to list recordings:', error);
        res.status(500).json({
            success: false,
            error: error.message
        });
    }
});

// Start server
app.listen(config.port, '0.0.0.0', () => {
    console.log(`Recording API server running on port ${config.port}`);
    console.log(`LiveKit URL: ${config.livekitUrl}`);
    console.log(`S3 Endpoint: ${config.s3Endpoint}`);
    console.log(`S3 Bucket: ${config.s3Bucket}`);
});
