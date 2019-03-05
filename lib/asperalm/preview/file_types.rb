module Asperalm
  module Preview
    class FileTypes
      # define how files are processed based on mime type
      SUPPORTED_MIME_TYPES={
        'application/json' => :plaintext,
        'application/mac-binhex40' => :office,
        'application/msword' => :office,
        'application/pdf' => :pdf,
        'application/postscript' => :image,
        'application/rtf' => :office,
        'application/vnd.3gpp.pic-bw-small' => :image,
        'application/vnd.hp-hpgl' => :image,
        'application/vnd.hp-pcl' => :image,
        'application/vnd.lotus-wordpro' => :office,
        'application/vnd.mobius.msl' => :image,
        'application/vnd.mophun.certificate' => :image,
        'application/vnd.ms-excel' => :office,
        'application/vnd.ms-excel.sheet.binary.macroenabled.12' => :office,
        'application/vnd.ms-excel.sheet.macroenabled.12' => :office,
        'application/vnd.ms-excel.template.macroenabled.12' => :office,
        'application/vnd.ms-powerpoint' => :office,
        'application/vnd.ms-powerpoint.presentation.macroenabled.12' => :office,
        'application/vnd.ms-powerpoint.template.macroenabled.12' => :office,
        'application/vnd.ms-word.document.macroenabled.12' => :office,
        'application/vnd.ms-word.template.macroenabled.12' => :office,
        'application/vnd.ms-works' => :office,
        'application/vnd.oasis.opendocument.chart' => :office,
        'application/vnd.oasis.opendocument.formula' => :office,
        'application/vnd.oasis.opendocument.graphics' => :office,
        'application/vnd.oasis.opendocument.graphics-template' => :office,
        'application/vnd.oasis.opendocument.presentation' => :office,
        'application/vnd.oasis.opendocument.presentation-template' => :office,
        'application/vnd.oasis.opendocument.spreadsheet' => :office,
        'application/vnd.oasis.opendocument.spreadsheet-template' => :office,
        'application/vnd.oasis.opendocument.text' => :office,
        'application/vnd.oasis.opendocument.text-template' => :office,
        'application/vnd.openxmlformats-officedocument.presentationml.presentation' => :office,
        'application/vnd.openxmlformats-officedocument.presentationml.slideshow' => :office,
        'application/vnd.openxmlformats-officedocument.presentationml.template' => :office,
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' => :office,
        'application/vnd.openxmlformats-officedocument.spreadsheetml.template' => :office,
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document' => :office,
        'application/vnd.openxmlformats-officedocument.wordprocessingml.template' => :office,
        'application/vnd.palm' => :office,
        'application/vnd.sun.xml.calc' => :office,
        'application/vnd.sun.xml.calc.template' => :office,
        'application/vnd.sun.xml.draw' => :office,
        'application/vnd.sun.xml.draw.template' => :office,
        'application/vnd.sun.xml.impress' => :office,
        'application/vnd.sun.xml.impress.template' => :office,
        'application/vnd.sun.xml.math' => :office,
        'application/vnd.sun.xml.writer' => :office,
        'application/vnd.sun.xml.writer.template' => :office,
        'application/vnd.wordperfect' => :office,
        'application/x-abiword' => :office,
        'application/x-director' => :image,
        'application/x-font-type1' => :image,
        'application/x-msmetafile' => :image,
        'application/x-mspublisher' => :office,
        'application/x-xfig' => :image,
        'audio/ogg' => :video,
        'font/ttf' => :image,
        'image/bmp' => :image,
        'image/cgm' => :image,
        'image/gif' => :image,
        'image/jpeg' => :image,
        'image/png' => :image,
        'image/sgi' => :image,
        'image/svg+xml' => :image,
        'image/tiff' => :image,
        'image/vnd.adobe.photoshop' => :image,
        'image/vnd.djvu' => :image,
        'image/vnd.dxf' => :office,
        'image/vnd.fpx' => :image,
        'image/vnd.ms-photo' => :image,
        'image/vnd.wap.wbmp' => :image,
        'image/webp' => :image,
        'image/x-cmx' => :office,
        'image/x-freehand' => :office,
        'image/x-icon' => :image,
        'image/x-mrsid-image' => :image,
        'image/x-pcx' => :image,
        'image/x-pict' => :office,
        'image/x-portable-anymap' => :image,
        'image/x-portable-bitmap' => :image,
        'image/x-portable-graymap' => :image,
        'image/x-portable-pixmap' => :image,
        'image/x-rgb' => :image,
        'image/x-tga' => :image,
        'image/x-xbitmap' => :image,
        'image/x-xpixmap' => :image,
        'image/x-xwindowdump' => :image,
        'text/csv' => :office,
        'text/html' => :office,
        'text/plain' => :plaintext,
        'text/troff' => :image,
        'video/h261' => :video,
        'video/h263' => :video,
        'video/h264' => :video,
        'video/mp4' => :video,
        'video/mpeg' => :video,
        'video/quicktime' => :video,
        'video/x-flv' => :video,
        'video/x-m4v' => :video,
        'video/x-matroska' => :video,
        'video/x-mng' => :image,
        'video/x-ms-wmv' => :video,
        'video/x-msvideo' => :video}

      # this is a way to add support for extensions that are otherwise not known by node api (mime type)
      SUPPORTED_EXTENSIONS={
        'aai' => :image,
        'art' => :image,
        'arw' => :image,
        'avs' => :image,
        'bmp2' => :image,
        'bmp3' => :image,
        'bpg' => :image,
        'cals' => :image,
        'cdr' => :office,
        'cin' => :image,
        'clipboard' => :image,
        'cmyk' => :image,
        'cmyka' => :image,
        'cr2' => :image,
        'crw' => :image,
        'cur' => :image,
        'cut' => :image,
        'cwk' => :office,
        'dbf' => :office,
        'dcm' => :image,
        'dcx' => :image,
        'dds' => :image,
        'dib' => :image,
        'dif' => :office,
        'divx' => :video,
        'dng' => :image,
        'dpx' => :image,
        'epdf' => :image,
        'epi' => :image,
        'eps2' => :image,
        'eps3' => :image,
        'epsf' => :image,
        'epsi' => :image,
        'ept' => :image,
        'exr' => :image,
        'fax' => :image,
        'fb2' => :office,
        'fits' => :image,
        'fodg' => :office,
        'fodp' => :office,
        'fods' => :office,
        'fodt' => :office,
        'gplt' => :image,
        'gray' => :image,
        'hdr' => :image,
        'hpw' => :office,
        'hrz' => :image,
        'info' => :image,
        'inline' => :image,
        'j2c' => :image,
        'j2k' => :image,
        'jbig' => :image,
        'jng' => :image,
        'jp2' => :image,
        'jpt' => :image,
        'jxr' => :image,
        'key' => :office,
        'mat' => :image,
        'mcw' => :office,
        'met' => :office,
        'miff' => :image,
        'mml' => :office,
        'mono' => :image,
        'mpr' => :image,
        'mrsid' => :image,
        'mrw' => :image,
        'mtv' => :image,
        'mvg' => :image,
        'mw' => :office,
        'mwd' => :office,
        'mxf' => :video,
        'nef' => :image,
        'numbers' => :office,
        'orf' => :image,
        'otb' => :image,
        'p7' => :image,
        'pages' => :office,
        'palm' => :image,
        'pam' => :image,
        'pcd' => :image,
        'pcds' => :image,
        'pef' => :image,
        'picon' => :image,
        'pict' => :image,
        'pix' => :image,
        'pm' => :office,
        'pm6' => :office,
        'pmd' => :office,
        'png00' => :image,
        'png24' => :image,
        'png32' => :image,
        'png48' => :image,
        'png64' => :image,
        'png8' => :image,
        'ps2' => :image,
        'ps3' => :image,
        'ptif' => :image,
        'pwp' => :image,
        'rad' => :image,
        'raf' => :image,
        'rfg' => :image,
        'rgba' => :image,
        'rla' => :image,
        'rle' => :image,
        'sct' => :image,
        'sfw' => :image,
        'sgf' => :office,
        'sgv' => :office,
        'slk' => :office,
        'sparse-color' => :image,
        'sun' => :image,
        'svm' => :office,
        'sylk' => :office,
        'tim' => :image,
        'uil' => :image,
        'uof' => :office,
        'uop' => :office,
        'uos' => :office,
        'uot' => :office,
        'uyvy' => :image,
        'vds' => :office,
        'vdx' => :office,
        'vicar' => :image,
        'viff' => :image,
        'vsdx' => :office,
        'wb2' => :office,
        'wk1' => :office,
        'wk3' => :office,
        'wn' => :office,
        'wpg' => :image,
        'wq1' => :office,
        'wq2' => :office,
        'x' => :image,
        'x3f' => :image,
        'xcf' => :image,
        'xlk' => :office,
        'ycbcr' => :image,
        'ycbcra' => :image,
        'yuv' => :image,
        'zabw' => :office}
    end
  end
end