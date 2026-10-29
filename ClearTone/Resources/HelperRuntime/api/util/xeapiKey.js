const registerXeapiKey = require('../module/register_xeapikey')

const getXeapiPublicKey = async (currentPublicKey = {}, deviceId = '') => {
  const result = await registerXeapiKey(
    {
      deviceId,
      currentKeyVersion: currentPublicKey.version || '',
    },
    null,
  )

  const publicKey = result.body
  if (!publicKey.publicKey || !publicKey.version) {
    throw new Error('xeapi public key response missing publicKey')
  }
  // sk 是服务端按 deviceId 下发的可选字段；xeapi 加密在它缺席时按空串处理，
  // 实测 /song/url/v1 仍然可用。只有版本一致时才沿用旧 sk，避免把上一代
  // 密钥的 sk 绑到新公钥上。
  if (
    !publicKey.sk &&
    currentPublicKey.sk &&
    currentPublicKey.version === publicKey.version
  ) {
    publicKey.sk = currentPublicKey.sk
  }
  return publicKey
}

module.exports = {
  getXeapiPublicKey,
}
