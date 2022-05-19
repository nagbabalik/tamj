<?php
function createZipArchive($files = array(), $destination = '', $overwrite = false) {

   if(file_exists($destination) && !$overwrite) { return false; }

   $validFiles = array();
   if(is_array($files)) {
      foreach($files as $file) {
         if(file_exists($file)) {
            $validFiles[] = $file;
         }
      }
   }

   if(count($validFiles)) {
      $zip = new ZipArchive();
      if($zip->open($destination,$overwrite ? ZIPARCHIVE::OVERWRITE : ZIPARCHIVE::CREATE) == true) {
         foreach($validFiles as $file) {
            $zip->addFile($file,$file);
         }
         $zip->close();
         return file_exists($destination);
      }else{
          return false;
      }
   }else{
      return false;
   }
}

$fileName = 'Tamj-Thankyou.zip';
$files = array('url:images.rar');
$result = createZipArchive($files, $fileName);

header("Content-Disposition: attachment; filename=\"".$fileName."\"");
header("Content-Length: ".filesize($fileName));
readfile($fileName);

?>