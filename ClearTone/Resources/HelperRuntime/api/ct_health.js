// 健康检查中间件，由主应用注入
// 在 app.js 之前加载或作为插件
module.exports = function(req, res, next) {
    if (req.path === '/ct_health') {
        const token = req.headers['x-ct-token'];
        const expectedToken = process.env.CT_AUTH_TOKEN;
        if (token && expectedToken && token === expectedToken) {
            res.status(200).json({ status: 'ok', timestamp: Date.now() });
        } else {
            res.status(401).json({ error: 'unauthorized' });
        }
        return;
    }
    next();
};
