'use strict';
const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");
const { getSignedUrl } = require("@aws-sdk/s3-request-presigner");

const s3Client = new S3Client({
  endpoint: process.env.MINIO_ENDPOINT, 
  region: "us-east-1",
  credentials: {
    accessKeyId: process.env.MINIO_ACCESS_KEY,
    secretAccessKey: process.env.MINIO_SECRET_KEY,
  },
  forcePathStyle: true,
});

module.exports = {
  async getPreSignedUrl(ctx) {
    const { fileName, fileType, userEmail } = ctx.request.body;    const user = ctx.state.user;

    if (!userEmail) return ctx.unauthorized("Email manquant.");

    const fileKey = `uploads/${userEmail}/${Date.now()}-${fileName}`;
    const command = new PutObjectCommand({
      Bucket: process.env.MINIO_BUCKET,
      Key: fileKey,
      ContentType: fileType,
    });

    try {
      const url = await getSignedUrl(s3Client, command, { expiresIn: 600 });
      ctx.send({ url, fileKey });
    } catch (err) {
      ctx.badRequest("Erreur S3 : " + err.message);
    }
  },
};