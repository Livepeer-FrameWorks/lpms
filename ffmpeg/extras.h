#ifndef _LPMS_EXTRAS_H_
#define _LPMS_EXTRAS_H_

typedef struct s_codec_info {
  char * format_name;
  char * video_codec;
  char * audio_codec;
  int    audio_bit_rate;
  int    pixel_format;
  int    width;
  int    height;
  double fps;
  double dur;
} codec_info, *pcodec_info;

int lpms_rtmp2hls(char *listen, char *outf, char *ts_tmpl, char *seg_time, char *seg_start);
int lpms_get_codec_info(char *fname, pcodec_info out);

#endif // _LPMS_EXTRAS_H_
