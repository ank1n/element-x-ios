const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
const { EgressClient, RoomServiceClient, EncodedFileOutput, S3Upload } = require('livekit-server-sdk');

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
    port: parseInt(process.env.PORT, 10) || 3001
};

// Initialize LiveKit Clients
const egressClient = new EgressClient(
    config.livekitUrl,
    config.livekitApiKey,
    config.livekitApiSecret
);

const roomClient = new RoomServiceClient(
    config.livekitUrl,
    config.livekitApiKey,
    config.livekitApiSecret
);

// Create router for API endpoints
const router = express.Router();

// Health check
router.get('/health', (req, res) => {
    res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// Helper function to find active room
async function findActiveRoom(requestedRoomName) {
    try {
        // List all active rooms using RoomServiceClient
        const rooms = await roomClient.listRooms();
        const activeRoomNames = rooms.map(r => r.name);

        console.log(`Requested room: ${requestedRoomName}, Active rooms: ${activeRoomNames.join(', ')}`);

        // If requested room exists, use it
        if (activeRoomNames.includes(requestedRoomName)) {
            return { roomName: requestedRoomName, found: true };
        }

        // If only one active room, use it
        if (activeRoomNames.length === 1) {
            console.log(`Auto-selecting only active room: ${activeRoomNames[0]}`);
            return { roomName: activeRoomNames[0], found: true };
        }

        return {
            roomName: null,
            found: false,
            availableRooms: activeRoomNames
        };
    } catch (error) {
        console.error('Error finding active room:', error);
        return { roomName: requestedRoomName, found: false };
    }
}

// Start recording
router.post('/api/recording/start', async (req, res) => {
    const { roomName: requestedRoomName, layout = 'grid-dark' } = req.body;

    if (!requestedRoomName) {
        return res.status(400).json({
            success: false,
            error: 'roomName is required'
        });
    }

    try {
        // Try to find the actual LiveKit room name
        const roomResult = await findActiveRoom(requestedRoomName);

        if (!roomResult.found) {
            const errorMsg = roomResult.availableRooms
                ? `Room '${requestedRoomName}' not found. Available rooms: ${roomResult.availableRooms.join(', ')}`
                : `Room '${requestedRoomName}' not found and no active rooms available`;

            return res.status(404).json({
                success: false,
                error: errorMsg,
                availableRooms: roomResult.availableRooms || []
            });
        }

        const roomName = roomResult.roomName;
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
            requestedRoomName: requestedRoomName,
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
router.post('/api/recording/stop', async (req, res) => {
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
router.get('/api/recording/status/:egressId', async (req, res) => {
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
                startedAt: egress.startedAt ? new Date(Number(egress.startedAt) / 1000000).toISOString() : null,
                endedAt: egress.endedAt ? new Date(Number(egress.endedAt) / 1000000).toISOString() : null
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
router.get('/api/recording/list', async (req, res) => {
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
                startedAt: e.startedAt ? new Date(Number(e.startedAt) / 1000000).toISOString() : null,
                endedAt: e.endedAt ? new Date(Number(e.endedAt) / 1000000).toISOString() : null
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

// Start recording (iOS-compatible path)
router.post('/start', async (req, res) => {
    const { roomName: requestedRoomName, layout = 'grid-dark' } = req.body;

    if (!requestedRoomName) {
        return res.status(400).json({
            success: false,
            error: 'roomName is required'
        });
    }

    try {
        // Try to find the actual LiveKit room name
        const roomResult = await findActiveRoom(requestedRoomName);

        if (!roomResult.found) {
            const errorMsg = roomResult.availableRooms
                ? `Room '${requestedRoomName}' not found. Available rooms: ${roomResult.availableRooms.join(', ')}`
                : `Room '${requestedRoomName}' not found and no active rooms available`;

            return res.status(404).json({
                success: false,
                error: errorMsg,
                availableRooms: roomResult.availableRooms || []
            });
        }

        const roomName = roomResult.roomName;
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
            requestedRoomName: requestedRoomName,
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

// Stop recording (iOS-compatible path)
router.post('/stop', async (req, res) => {
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

// Get recording status (iOS-compatible path)
router.get('/status/:egressId', async (req, res) => {
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
                startedAt: egress.startedAt ? new Date(Number(egress.startedAt) / 1000000).toISOString() : null,
                endedAt: egress.endedAt ? new Date(Number(egress.endedAt) / 1000000).toISOString() : null
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

// Mount router at both root and /recording-api for K8s ingress compatibility
app.use('/', router);
app.use('/recording-api', router);

// Start server
app.listen(config.port, '0.0.0.0', () => {
    console.log(`Recording API ready on port ${config.port}`);
});
