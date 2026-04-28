module.exports = {
  routes: [
    {
      method: 'POST',
      path: '/s3-upload/get-url',
      handler: 's3-upload.getPreSignedUrl',
      config: {
        auth: false, 
      },
    },
  ],
};