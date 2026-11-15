/**
 * 网易云音乐 (NCM) 逐字动感歌词 (YRC) 检测脚本
 *
 * 用途：
 * 1. 验证网易云官方 API 接口中歌曲是否真实下发 YRC 逐字动感歌词；
 * 2. 辅助在 Lazer 客户端中挑选具备逐字歌词的曲目进行卡拉OK效果实测。
 *
 * 使用方法：
 *   node check_yrc.js                 # 运行内置的 10 首精选曲目测试 (含中文、欧美、日文、术力口)
 *   node check_yrc.js "歌曲名 歌手"   # 动态搜索并检测指定歌曲
 */

const crypto = require('crypto');
const https = require('https');

// 网易云 EAPI 固定通信密钥 (与 ncm/config.lua 保持完全一致)
const EAPI_KEY = Buffer.from('e82ckenh8dichen8');

function eapiEncrypt(urlPath, dataObj) {
  const jsonStr = JSON.stringify(dataObj);
  const message = `nobody${urlPath}use${jsonStr}md5forencrypt`;
  const digest = crypto.createHash('md5').update(message).digest('hex');
  const data = `${urlPath}-36cd479b6b5-${jsonStr}-36cd479b6b5-${digest}`;
  
  const cipher = crypto.createCipheriv('aes-128-ecb', EAPI_KEY, null);
  cipher.setAutoPadding(true);
  let enc = cipher.update(data, 'utf8', 'hex');
  enc += cipher.final('hex');
  return enc.toUpperCase();
}

function eapiDecrypt(buffer) {
  try {
    const decipher = crypto.createDecipheriv('aes-128-ecb', EAPI_KEY, null);
    decipher.setAutoPadding(true);
    let dec = decipher.update(buffer);
    dec = Buffer.concat([dec, decipher.final()]);
    return JSON.parse(dec.toString('utf8'));
  } catch (e) {
    return JSON.parse(buffer.toString('utf8'));
  }
}

function requestNcm(urlPath, dataObj) {
  return new Promise((resolve, reject) => {
    dataObj.header = {
      os: 'pc',
      appver: '3.1.17.204416',
      osver: 'Microsoft-Windows-10-Professional-build-19045-64bit',
      channel: 'netease',
      requestId: `${Date.now()}_${Math.random().toString(16).slice(2, 8)}`
    };
    const encParams = eapiEncrypt(urlPath, dataObj);
    const postData = `params=${encodeURIComponent(encParams)}`;
    
    const req = https.request('https://interfacepc.music.163.com/eapi/song/lyric/v1', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 NeteaseMusicDesktop/3.1.29.205117',
        'Cookie': 'os=pc; appver=3.1.17.204416; channel=netease;'
      }
    }, (res) => {
      let chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => {
        try {
          resolve(eapiDecrypt(Buffer.concat(chunks)));
        } catch (err) {
          reject(err);
        }
      });
    });
    req.on('error', reject);
    req.write(postData);
    req.end();
  });
}

function searchSong(keyword) {
  return new Promise((resolve, reject) => {
    const query = encodeURIComponent(keyword);
    const req = https.request(`https://music.163.com/api/search/get/web?s=${query}&type=1&offset=0&total=true&limit=5`, {
      method: 'GET',
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Referer': 'https://music.163.com/',
        'Cookie': 'os=pc;'
      }
    }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          const json = JSON.parse(data);
          resolve(json.result?.songs || []);
        } catch (e) {
          resolve([]);
        }
      });
    });
    req.on('error', reject);
    req.end();
  });
}

async function testSongItem(target) {
  let songId, songTitle, singer, category;

  if (typeof target === 'object' && target.id) {
    songId = target.id;
    songTitle = target.title;
    singer = target.singer;
    category = target.category || '精选曲目';
  } else {
    category = '动态搜索';
    const keyword = (typeof target === 'string' ? target : target.query).trim();
    if (/^\d+$/.test(keyword)) {
      songId = keyword;
      songTitle = `ID:${songId}`;
      singer = '网易云歌曲';
    } else {
      const songs = await searchSong(keyword);
      if (!songs || songs.length === 0) {
        console.log(`[未搜到] ${keyword}`);
        return;
      }
      const s = songs[0];
      songId = s.id;
      songTitle = s.name;
      singer = s.artists?.map(a => a.name).join('/') || '未知';
    }
  }

  try {
    const res = await requestNcm('/api/song/lyric/v1', {
      id: songId,
      cp: false,
      tv: -1,
      lv: -1,
      rv: -1,
      kv: -1,
      yv: -1,
      ytv: -1,
      yrv: -1
    });

    const hasYrc = !!(res.yrc && res.yrc.lyric && res.yrc.lyric.trim().length > 0);
    const hasLrc = !!(res.lrc && res.lrc.lyric && res.lrc.lyric.trim().length > 0);
    const hasTrans = !!(res.tlyric && res.tlyric.lyric && res.tlyric.lyric.trim().length > 0);

    console.log(`--------------------------------------------------------------------------------`);
    console.log(`[${category}] 《${songTitle}》 - ${singer} (网易云ID: ${songId})`);
    console.log(`逐字歌词 (YRC): ${hasYrc ? '✅ 支持 (含逐字精确起止时间)' : '❌ 无逐字 (仅普通逐行)'}`);
    console.log(`逐行歌词 (LRC): ${hasLrc ? '✅ 支持' : '❌ 无'}`);
    console.log(`双语翻译:       ${hasTrans ? '✅ 支持' : '❌ 无'}`);

    if (hasYrc) {
      const yrcPreview = res.yrc.lyric
        .split('\n')
        .map(l => l.trim())
        .filter(l => l.startsWith('[') && l.includes('('))
        .slice(0, 2)
        .join('\n');
      if (yrcPreview) {
        console.log(`\n  YRC 格式样例:`);
        yrcPreview.split('\n').forEach(line => console.log(`    ${line}`));
      }
    }
  } catch (err) {
    console.log(`请求《${songTitle || target}》失败: ${err.message}`);
  }
}

// 内置 10 首经实测 100% 具备网易云官方逐字歌词 (YRC) 的经典/流行曲目
const DEFAULT_PRESET_SONGS = [
  // 1-4. 华语流行 (经典与高热度)
  { category: '华语流行', id: 25727803, title: '修炼爱情', singer: '林俊杰' },
  { category: '华语流行', id: 32507038, title: '演员', singer: '薛之谦' },
  { category: '华语流行', id: 449818741, title: '光年之外', singer: 'G.E.M.邓紫棋' },
  { category: '华语流行', id: 1293886117, title: '年少有为', singer: '李荣浩' },

  // 5-7. 欧美热门 (English Pop / R&B)
  { category: '欧美流行', id: 1406633327, title: 'Blinding Lights', singer: 'The Weeknd' },
  { category: '欧美流行', id: 1355147933, title: 'bad guy', singer: 'Billie Eilish' },
  { category: '欧美流行', id: 1382576173, title: 'Cruel Summer', singer: 'Taylor Swift' },
  { category: '欧美流行', id: 26060065, title: 'Counting Stars', singer: 'OneRepublic' },

  // 8-9. 日文流行与术力口 (J-Pop / Vocaloid)
  { category: '日文流行', id: 541687281, title: 'Lemon', singer: '米津玄師' },
  { category: '术力口 / Vocaloid', id: 287035, title: '千本桜', singer: '黒うさP / 初音ミク' }
];

async function main() {
  const customQuery = process.argv.slice(2).join(' ').trim();

  if (customQuery) {
    console.log(`🔍 正在查询指定歌曲: "${customQuery}" ...\n`);
    await testSongItem(customQuery);
  } else {
    console.log(`🎵 开始检测网易云官方 10 首精选逐字动感歌词 (YRC) 曲目:\n`);
    for (const song of DEFAULT_PRESET_SONGS) {
      await testSongItem(song);
    }
    console.log(`\n================================================================================`);
    console.log(`提示：可以在 Lazer 中登录网易云音乐，搜索点播上述任意一首歌曲验证逐字歌词效果！`);
  }
}

main();
