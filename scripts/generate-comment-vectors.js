// Run from the repository root with the bundled Node runtime. No network or credentials.
const comments = require('../ClearTone/Resources/HelperRuntime/api/module/comment_new.js')
const likes = require('../ClearTone/Resources/HelperRuntime/api/module/comment_like.js')
const { eapi } = require('../ClearTone/Resources/HelperRuntime/api/util/crypto.js')
const reads = []
for (const sortType of ['99', '2', '3']) {
  for (const pageNo of ['1', '2']) {
    const query = { id: '42', type: '0', sortType, pageNo, pageSize: '20' }
    if (sortType === '3' && pageNo === '2') query.cursor = '1758700000123'
    comments({ ...query }, (uri, payload) => {
      reads.push({ query, uri, payload: JSON.stringify(payload), ciphertext: eapi(uri, payload).params })
    })
  }
}
const writes = []
for (const t of ['1', '0']) {
  const query = { id: '42', cid: '99', type: '0', t }
  likes({ ...query }, (uri, payload) => writes.push({ query, uri, payload: JSON.stringify(payload) }))
}
process.stdout.write(JSON.stringify({ reads, writes }, null, 2) + '\n')
